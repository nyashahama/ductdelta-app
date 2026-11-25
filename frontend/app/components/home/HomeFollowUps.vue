<script setup lang="ts">
import { casePath, formatDecimal } from '~/components/cases/case-data'
import { formatDeadline, type FollowUpAction, type FollowUpPage } from '~/types/overview'
import { api, reportError } from '~/utils/api'

const props = defineProps<{ project: string, version: number }>()
const emit = defineEmits<{ open: [id: string], observation: [id: string], sessionExpired: [] }>()
const page = ref(1)
const attempt = ref(0)
const result = shallowRef<FollowUpPage>()
const loading = ref(true)
const error = ref('')

const actionLabels = {
  notice: 'Send or record notice dispatch',
  revised_notice: 'Send or record dispatch of revised notice',
  instruction: 'Confirm written instruction',
  quote: 'Prepare quote',
  quote_decision: 'Follow up on quote decision',
  quote_lines: 'Resolve open or disputed quote lines',
  uncertified: 'Review value still to certify',
  application: 'Check certification of payment application',
  collect: 'Check certified payment',
  credit: 'Reconcile certificate credit',
  retention: 'Track retention release',
  unallocated: 'Match cash receipts',
  review: 'Review open case'
} satisfies Record<FollowUpAction['kind'], string>

const referenceLabels = { instruction: 'Instruction', quote: 'Quote', application: 'Application', certificate: 'Certificate' }

watch([page, attempt, () => props.version], async ([requestedPage], _, onCleanup) => {
  const controller = new AbortController()
  onCleanup(() => controller.abort())
  loading.value = true
  error.value = ''
  try {
    const list = await api<FollowUpPage>(`/api/projects/${props.project}/follow-ups?page=${requestedPage}`, { signal: controller.signal })
    if (controller.signal.aborted) return
    if (!list.cases.length && requestedPage > 1) {
      page.value = requestedPage - 1
      return
    }
    result.value = list
  } catch (cause) {
    if (controller.signal.aborted) return
    result.value = undefined
    error.value = reportError(cause, () => emit('sessionExpired'))
  } finally {
    if (!controller.signal.aborted) loading.value = false
  }
}, { immediate: true })

function actionLabel(action: FollowUpAction) {
  return action.kind === 'uncertified' && action.reference ? 'Follow up on certification' : actionLabels[action.kind]
}
</script>

<template>
  <section aria-labelledby="change-follow-ups" :aria-busy="loading" class="min-w-0 space-y-3">
    <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
      <h2 id="change-follow-ups" class="font-semibold text-highlighted">
        Change follow-ups
      </h2>
      <span v-if="result?.cases.some(item => item.actions.some(action => 'amount' in action && action.amount != null))" class="text-xs text-muted">
        ZAR excl. VAT
      </span>
    </div>

    <UAlert
      v-if="error"
      role="alert"
      color="error"
      variant="subtle"
      :title="error"
    >
      <template #actions>
        <UButton
          color="neutral"
          variant="outline"
          label="Retry follow-ups"
          @click="attempt++"
        />
      </template>
    </UAlert>
    <p v-else-if="!result" role="status" class="text-sm text-muted">
      Loading change follow-ups…
    </p>
    <p v-else-if="!result.cases.length" class="rounded-lg border border-default p-4 text-sm text-muted">
      No open change cases to follow up.
    </p>
    <template v-else>
      <ul class="divide-y divide-default rounded-lg border border-default">
        <li v-for="item in result.cases" :key="item.id" class="grid min-w-0 gap-3 px-4 py-3 lg:grid-cols-3 lg:gap-4">
          <h3 class="min-w-0">
            <UButton
              color="neutral"
              variant="link"
              class="p-0 text-left font-semibold whitespace-normal wrap-anywhere text-highlighted"
              trailing-icon="i-lucide-arrow-up-right"
              :label="item.title"
              @click="emit('open', item.id)"
            />
          </h3>
          <ul aria-label="Follow-up actions" class="min-w-0 space-y-2 text-sm">
            <li v-for="action in item.actions" :key="action.kind" class="wrap-anywhere">
              <span class="font-medium text-highlighted">{{ actionLabel(action) }}</span>
              <strong v-if="'amount' in action && action.amount != null" class="ms-2 whitespace-nowrap tabular-nums">
                R {{ formatDecimal(action.amount) }}
              </strong>
              <span v-if="action.kind === 'quote_lines'" class="ms-2 text-muted">{{ action.count }}</span>
              <span v-if="action.kind === 'notice' || action.kind === 'revised_notice' || action.kind === 'application'" class="block text-xs text-muted">
                {{ action.reference }}<template v-if="action.kind === 'notice' && action.due_at"> · Due {{ formatDeadline(action.due_at) }}</template>
              </span>
              <p v-if="action.kind === 'uncertified' && action.reference" class="text-xs text-muted">
                Agreed balance · Recorded application {{ action.reference }}
              </p>
              <p v-if="action.kind === 'collect' && item.evidence.unpaid_certificates.length" class="text-xs text-muted">
                {{ item.evidence.unpaid_certificates.length === 1 ? 'Unpaid certificate' : 'Unpaid certificates' }} · {{ item.evidence.unpaid_certificates.join(', ') }}
              </p>
              <UButton
                v-if="(action.kind === 'notice' || action.kind === 'revised_notice') && action.copy_id"
                external
                color="primary"
                variant="link"
                class="block p-0 text-left whitespace-normal"
                :to="`${casePath(project, item.id)}/notices/${action.notice_id}/copies/${action.copy_id}/download`"
                :label="`Download notice version ${action.version}`"
              />
            </li>
          </ul>
          <div
            v-if="item.evidence.observation_id || item.evidence.references.length || item.evidence.file_count"
            class="min-w-0 space-y-1 text-xs text-muted"
          >
            <h4 class="font-medium text-highlighted">
              Evidence on file
            </h4>
            <p v-if="item.evidence.references.length" class="wrap-anywhere">
              {{ item.evidence.references.map(record => `${referenceLabels[record.kind]} ${record.reference}`).join(' · ') }}
            </p>
            <UButton
              v-if="item.evidence.observation_id"
              color="primary"
              variant="link"
              size="xs"
              label="Source observation"
              class="block p-0 text-left"
              @click="emit('observation', item.evidence.observation_id)"
            />
            <ul v-if="item.evidence.files.length" class="space-y-1">
              <li v-for="file in item.evidence.files" :key="file.id" class="flex flex-wrap items-baseline gap-x-2">
                <UButton
                  external
                  color="primary"
                  variant="link"
                  size="xs"
                  :label="file.filename"
                  :aria-label="`Download ${file.filename}`"
                  :to="`${casePath(project, item.id)}/files/${file.id}`"
                  class="max-w-full p-0 text-left whitespace-normal wrap-anywhere"
                />
                <span v-if="file.access_class === 'finance'">Finance only</span>
              </li>
            </ul>
            <UButton
              v-if="item.evidence.file_count > item.evidence.files.length"
              color="primary"
              variant="link"
              size="xs"
              class="p-0"
              :label="`All ${item.evidence.file_count} files in case`"
              @click="emit('open', item.id)"
            />
          </div>
        </li>
      </ul>
      <nav v-if="page > 1 || result.has_more" aria-label="Change follow-up pages" class="flex items-center justify-end gap-2">
        <UButton
          size="xs"
          color="neutral"
          variant="outline"
          :disabled="loading || page === 1"
          label="Previous"
          @click="page--"
        />
        <span class="text-xs text-muted" role="status">Page {{ page }}</span>
        <UButton
          size="xs"
          color="neutral"
          variant="outline"
          :disabled="loading || !result.has_more"
          label="Next"
          @click="page++"
        />
      </nav>
    </template>
  </section>
</template>
