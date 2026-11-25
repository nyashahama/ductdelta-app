<script setup lang="ts">
import { casePath, formatDecimal } from '~/components/cases/case-data'
import { formatDeadline, type FollowUpAction, type FollowUpCase } from '~/types/overview'
import { followUpActions } from './follow-up-action'

const props = defineProps<{ project: string, item: FollowUpCase }>()
const emit = defineEmits<{ open: [id: string], observation: [id: string] }>()
const filesPath = computed(() => casePath(props.project, props.item.id))
const evidence = computed(() => props.item.evidence)
const hasEvidence = computed(() => evidence.value.observation_id || evidence.value.references.length || evidence.value.file_count)
const hasMoney = computed(() => props.item.actions.some(action => 'amount' in action && action.amount != null))
const referenceLabels = { instruction: 'Instruction', quote: 'Quote', application: 'Application', certificate: 'Certificate' }

function actionLabel(action: FollowUpAction) {
  return action.kind === 'uncertified' && action.reference ? 'Follow up on certification' : followUpActions[action.kind].label
}
</script>

<template>
  <section aria-label="Follow-up details" class="min-w-0 bg-default p-3.5 sm:p-6">
    <div class="mb-2.5 grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-5">
      <h3 class="sr-only min-w-0 text-2xl leading-tight font-semibold tracking-tight wrap-anywhere text-highlighted lg:not-sr-only lg:col-start-1 lg:row-start-1">
        {{ item.title }}
      </h3>
      <UButton
        color="primary"
        size="sm"
        label="Open case"
        trailing-icon="i-lucide-arrow-up-right"
        class="col-start-2 row-start-1 justify-self-end rounded-lg text-black"
        @click="emit('open', item.id)"
      />
      <div class="col-start-1 row-start-1 flex flex-wrap items-baseline gap-x-2 lg:col-span-2 lg:row-start-2 lg:justify-between">
        <h4 class="text-sm font-semibold text-highlighted">
          Next actions
        </h4>
        <span v-if="hasMoney" class="text-xs text-muted">ZAR excl. VAT</span>
      </div>
    </div>
    <ul aria-label="Follow-up actions" class="divide-y divide-default overflow-hidden rounded-xl border border-default bg-muted/35">
      <li v-for="action in item.actions" :key="action.kind" class="grid grid-cols-[auto_minmax(0,1fr)_auto] items-start gap-x-3 gap-y-0.5 px-3 py-3.5 sm:px-4">
        <span :class="followUpActions[action.kind].tone" class="row-span-2 grid size-8 place-items-center rounded-lg">
          <UIcon :name="followUpActions[action.kind].icon" class="size-4" aria-hidden="true" />
        </span>
        <span class="col-start-2 row-start-1 text-sm font-semibold wrap-anywhere text-highlighted">{{ actionLabel(action) }}</span>
        <strong
          v-if="'amount' in action && action.amount != null"
          class="col-start-3 row-start-1 max-w-24 text-right text-base font-semibold tracking-tight wrap-anywhere text-highlighted tabular-nums sm:max-w-56 sm:text-lg"
        >
          R {{ formatDecimal(action.amount) }}
        </strong>
        <span v-if="action.kind === 'quote_lines'" class="col-start-3 row-start-1 text-sm font-medium text-muted tabular-nums">
          {{ action.count }} {{ action.count === 1 ? 'line' : 'lines' }}
        </span>
        <p
          v-if="action.kind === 'notice' || action.kind === 'revised_notice' || action.kind === 'application' || action.kind === 'quote_decision'"
          class="col-span-2 col-start-2 text-xs/5 wrap-anywhere text-muted"
        >
          {{ action.reference }}<template v-if="action.kind === 'notice' && action.due_at">
            · Due {{ formatDeadline(action.due_at) }}
          </template>
        </p>
        <p v-if="action.kind === 'uncertified' && action.reference" class="col-span-2 col-start-2 text-xs/5 wrap-anywhere text-muted">
          Agreed balance · Application <span class="inline-block max-w-full">{{ action.reference }}</span>
        </p>
        <p v-if="action.kind === 'collect' && evidence.unpaid_certificates.length" class="col-span-2 col-start-2 text-xs/5 wrap-anywhere text-muted">
          {{ evidence.unpaid_certificates.length === 1 ? 'Unpaid certificate' : 'Unpaid certificates' }} · {{ evidence.unpaid_certificates.join(', ') }}
        </p>
        <UButton
          v-if="(action.kind === 'notice' || action.kind === 'revised_notice') && action.copy_id"
          external
          color="primary"
          variant="link"
          size="sm"
          icon="i-lucide-download"
          class="col-span-2 col-start-2 mt-1 justify-self-start p-0 text-left whitespace-normal"
          :to="`${filesPath}/notices/${action.notice_id}/copies/${action.copy_id}/download`"
          :label="`Download notice version ${action.version}`"
        />
      </li>
    </ul>

    <div v-if="hasEvidence" class="mt-6 space-y-3">
      <h4 class="text-sm font-semibold text-highlighted">
        Evidence on file
      </h4>
      <dl v-if="evidence.references.length" class="flex flex-wrap gap-2">
        <div v-for="record in evidence.references" :key="record.kind" class="flex max-w-full flex-wrap gap-x-1.5 rounded-md bg-elevated/65 px-2.5 py-1 text-xs wrap-anywhere">
          <dt class="text-muted">
            {{ referenceLabels[record.kind] }}
          </dt>
          <dd class="min-w-0 font-medium text-highlighted">
            {{ record.reference }}
          </dd>
        </div>
      </dl>
      <ul v-if="evidence.observation_id || evidence.files.length" class="grid gap-2 sm:grid-cols-2">
        <li v-if="evidence.observation_id" class="min-w-0">
          <UButton
            color="neutral"
            variant="outline"
            icon="i-lucide-clipboard-list"
            label="Source observation"
            trailing-icon="i-lucide-arrow-up-right"
            class="h-full w-full rounded-lg px-3 py-2.5 text-left whitespace-normal hover:text-primary"
            :ui="{ label: 'flex-1 wrap-anywhere' }"
            @click="emit('observation', evidence.observation_id)"
          />
        </li>
        <li v-for="file in evidence.files" :key="file.id" class="min-w-0">
          <UButton
            external
            color="neutral"
            variant="outline"
            :icon="file.access_class === 'finance' ? 'i-lucide-lock-keyhole' : 'i-lucide-file-text'"
            trailing-icon="i-lucide-download"
            :aria-label="`Download ${file.filename}`"
            :to="`${filesPath}/files/${file.id}`"
            class="h-full w-full rounded-lg px-3 py-2.5 text-left whitespace-normal hover:text-primary"
          >
            <span class="min-w-0 flex-1 wrap-anywhere">
              {{ file.filename }}
              <span v-if="file.access_class === 'finance'" class="block text-xs font-normal text-muted">Finance only</span>
            </span>
          </UButton>
        </li>
      </ul>
      <UButton
        v-if="evidence.file_count > evidence.files.length"
        color="primary"
        variant="link"
        size="sm"
        trailing-icon="i-lucide-arrow-up-right"
        class="p-0"
        :label="`All ${evidence.file_count} files in case`"
        @click="emit('open', item.id)"
      />
    </div>
  </section>
</template>
