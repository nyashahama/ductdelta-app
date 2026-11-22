<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { ApiError, api, reportError, requestJson } from '../../utils/api'
import { retryOperation, type Operation } from './case-data'
import { deadlineModes, noticeRulePath, type DeadlineMode, type NoticeRule, type NoticeRuleSettings, type RuleFields } from './notice-rule'
import NoticeRuleSummary from './NoticeRuleSummary.vue'
import { useActiveScope, useCaseResource } from './useCaseResource'

const props = defineProps<{ project: string }>()
const emit = defineEmits<{ 'session-expired': [] }>()
const path = computed(() => noticeRulePath(props.project))
const { resource, reload } = useCaseResource<NoticeRuleSettings>(path, () => emit('session-expired'))
const active = useActiveScope()
const busy = ref(false)
const message = ref('')
const error = ref('')
const stale = ref(false)
const emptyFields: RuleFields = {
  agreement: '', clause: '', issuer_actor_id: '', authority: '', recipient: '',
  service_method: '', timezone: '', trigger: ''
}
const draft = ref({ ...emptyFields })
const mode = ref<DeadlineMode>('elapsed_hours')
const windowSize = ref<number>()
const manualInstructions = ref('')
let operation: Operation | null = null

const fields = [
  { name: 'agreement', label: 'Agreement reference', length: 160 },
  { name: 'clause', label: 'Clause', length: 160 },
  { name: 'authority', label: 'Issuing authority', length: 160 },
  { name: 'recipient', label: 'Recipient', length: 240 },
  { name: 'service_method', label: 'Service method', length: 240 },
  { name: 'timezone', label: 'Contract time zone', length: 100, placeholder: 'Africa/Johannesburg' },
  { name: 'trigger', label: 'Trigger event', length: 240 }
] as const
const settings = computed(() => resource.value.kind === 'ready' ? resource.value.data : undefined)
const issuers = computed(() => settings.value?.issuers.map(({ id, name }) => ({ label: name, value: id })) ?? [])

watch(settings, (loaded) => {
  if (!loaded) return
  const rule = loaded.rule
  const next = { ...emptyFields }
  if (rule) {
    for (const field of fields) next[field.name] = rule[field.name]
    if (loaded.issuers.some(({ id }) => id === rule.issuer_actor_id)) next.issuer_actor_id = rule.issuer_actor_id
  }
  draft.value = next
  mode.value = rule?.deadline_mode ?? 'elapsed_hours'
  windowSize.value = rule && rule.deadline_mode !== 'manual' ? rule.window : undefined
  manualInstructions.value = rule?.deadline_mode === 'manual' ? rule.manual_instructions : ''
})

function refresh() {
  stale.value = false
  error.value = ''
  reload()
}

async function publish() {
  const current = settings.value
  if (!current?.can_manage || busy.value || stale.value) return
  const rule = {
    ...draft.value,
    deadline_mode: mode.value,
    ...(mode.value === 'manual' ? { manual_instructions: manualInstructions.value } : { window: windowSize.value })
  }
  const input = { expected_version: current.rule?.version ?? 0, rule }
  operation = retryOperation(operation, input)
  busy.value = true
  error.value = ''
  message.value = ''
  try {
    const published = await api<NoticeRule>(path.value, requestJson({ operation_id: operation.id, ...input }))
    if (!active()) return
    operation = null
    message.value = `Rule version ${published.version} published.`
    reload()
  } catch (cause) {
    if (!active()) return
    error.value = reportError(cause, () => emit('session-expired'))
    stale.value = cause instanceof ApiError && cause.status === 409
  } finally {
    if (active()) busy.value = false
  }
}
</script>

<template>
  <section class="mx-auto w-full max-w-3xl space-y-4" aria-label="Project notice rules">
    <p v-if="message" role="status" class="text-sm text-success">
      {{ message }}
    </p>
    <p v-if="resource.kind === 'loading'" role="status" class="text-muted">
      Loading notice rules…
    </p>
    <UAlert
      v-else-if="resource.kind === 'error'"
      :title="resource.message"
      color="error"
      variant="subtle"
    >
      <template #actions>
        <UButton
          color="neutral"
          variant="outline"
          label="Retry loading notice rules"
          @click="refresh"
        />
      </template>
    </UAlert>
    <template v-else-if="settings">
      <UCard as="section" aria-label="Active rule">
        <template #header>
          <h2 class="font-semibold text-highlighted">
            {{ settings.rule ? `Active rule · Version ${settings.rule.version}` : 'No notice rule published' }}
          </h2>
        </template>
        <NoticeRuleSummary v-if="settings.rule" :rule="settings.rule" />
        <p v-else class="text-sm text-muted">
          Project members with direction access can record notices and enter a deadline when known.
        </p>
      </UCard>

      <UCard v-if="settings.can_manage" as="section" aria-label="Notice rule administration">
        <template #header>
          <h2 class="font-semibold text-highlighted">
            Publish notice rule
          </h2>
          <p class="mt-1 text-sm text-muted">
            Check the signed agreement before publishing. A new version applies to new notices.
          </p>
        </template>
        <p v-if="!issuers.length" class="text-sm text-muted">
          Assign direction access to an authorized issuer in Company settings before publishing.
        </p>
        <form v-else aria-label="Publish notice rule" @submit.prevent="publish">
          <fieldset :disabled="busy" class="grid min-w-0 gap-4 sm:grid-cols-2">
            <UFormField
              v-for="field in fields"
              :key="field.name"
              :label="field.label"
              :name="field.name"
              required
            >
              <UInput
                v-model="draft[field.name]"
                :aria-label="field.label"
                :placeholder="'placeholder' in field ? field.placeholder : undefined"
                :maxlength="field.length"
                class="w-full"
                required
              />
            </UFormField>
            <UFormField label="Authorized issuer" name="issuer_actor_id" required>
              <USelect
                v-model="draft.issuer_actor_id"
                aria-label="Authorized issuer"
                :items="issuers"
                placeholder="Choose a project member"
                class="w-full"
                required
              />
            </UFormField>
            <UFormField label="Deadline mechanism" name="deadline_mode" required>
              <USelect
                v-model="mode"
                aria-label="Deadline mechanism"
                :items="[...deadlineModes]"
                class="w-full"
                required
              />
            </UFormField>
            <UFormField
              v-if="mode === 'manual'"
              label="Manual deadline instructions"
              name="manual_instructions"
              required
            >
              <UTextarea
                v-model="manualInstructions"
                aria-label="Manual deadline instructions"
                :maxlength="4000"
                class="w-full"
                required
              />
            </UFormField>
            <UFormField
              v-else
              :label="mode === 'elapsed_hours' ? 'Elapsed hours' : 'Calendar days'"
              name="window"
              :help="mode === 'calendar_days' ? 'Due at the end of the target day in the contract time zone.' : 'Hours run continuously from the trigger instant.'"
              required
            >
              <UInput
                v-model.number="windowSize"
                :aria-label="mode === 'elapsed_hours' ? 'Elapsed hours' : 'Calendar days'"
                class="w-full"
                type="number"
                min="1"
                max="999"
                step="1"
                required
              />
            </UFormField>
          </fieldset>
          <p v-if="error" role="alert" class="mt-4 text-sm text-error">
            {{ error }}
          </p>
          <div class="mt-4 flex flex-wrap gap-2">
            <UButton
              label="Publish rule"
              type="submit"
              :loading="busy"
              :disabled="stale"
            />
            <UButton
              v-if="stale"
              color="neutral"
              variant="outline"
              label="Refresh notice rule"
              @click="refresh"
            />
          </div>
        </form>
      </UCard>
    </template>
  </section>
</template>
