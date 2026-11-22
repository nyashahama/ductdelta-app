<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { ApiError, api, reportError, requestJson } from '../../utils/api'
import { actionFields, dispositionChoices } from './action-fields'
import { actionData, actions, availableActions, eventsOf, formatDecimal, retryOperation, type ActionKind, type CaseIssuedNoticeCopy, type CaseRecord, type Operation } from './case-data'
import CaseActionField from './CaseActionField.vue'
import CaseNoticeServiceFields from './CaseNoticeServiceFields.vue'
import NoticeRuleSummary from './NoticeRuleSummary.vue'
import { noticeRulePath, type NoticeRuleSettings } from './notice-rule'
import { useActiveScope, useCaseResource } from './useCaseResource'

const props = defineProps<{ record: CaseRecord, permission: 'read' | 'capture', path: string, project: string, issuedCopies: CaseIssuedNoticeCopy[] }>()
const emit = defineEmits<{ 'saved': [], 'session-expired': [] }>()
const kind = ref<ActionKind>()
const error = ref('')
const refreshNotice = ref(false)
const busy = ref(false)
const active = useActiveScope()
const available = computed(() => availableActions(props.record, props.permission))
const choices = computed(() => available.value.map(value => ({ label: actions[value].label, value })))
const selected = computed(() => kind.value && available.value.includes(kind.value) ? kind.value : undefined)
const settingsPath = computed(() => selected.value === 'notice' ? noticeRulePath(props.project) : null)
const { resource: noticeSettings, reload: reloadNotice } = useCaseResource<NoticeRuleSettings>(
  settingsPath, () => emit('session-expired')
)
const rule = computed(() => noticeSettings.value.kind === 'ready' ? noticeSettings.value.data.rule ?? undefined : undefined)
const noticeBlocked = computed(() => {
  if (selected.value !== 'notice' || noticeSettings.value.kind !== 'ready' || !rule.value) return ''
  if (rule.value.issuer_actor_id !== noticeSettings.value.data.actor_id) {
    return 'Only the configured issuer can record this notice.'
  }
  if (props.record.agreement && props.record.agreement !== rule.value.agreement) {
    return 'The case agreement differs from the active notice rule. Ask a project administrator to review the rule.'
  }
  return ''
})
const canEnterAction = computed(() => selected.value !== 'notice'
  || (noticeSettings.value.kind === 'ready' && !noticeBlocked.value))
const noticeDraft = ref<Record<string, string>>({})
const fields = computed(() => {
  const action = selected.value
  if (!action) return []
  const formFields = actionFields(action, props.record, rule.value)
  return action === 'notice'
    ? formFields.map(field => ({ ...field, value: noticeDraft.value[field.name] ?? field.value }))
    : formFields
})
const quoteRows = ref([1])
let nextRow = 2
let operation: Operation | null = null

const currentQuote = computed(() => eventsOf(props.record, 'quote').at(-1))
const currentDecision = computed(() => eventsOf(props.record, 'decision').reverse().find(event => event.data.quote === currentQuote.value?.id))

watch(kind, () => {
  operation = null
  error.value = ''
  refreshNotice.value = false
  noticeDraft.value = {}
  if (kind.value === 'notice') reloadNotice()
  quoteRows.value = [1]
  nextRow = 2
})

function addQuoteLine() {
  quoteRows.value.push(nextRow++)
}

async function save(event: SubmitEvent) {
  const action = selected.value
  if (!action || !canEnterAction.value || busy.value || refreshNotice.value) return
  const form = new FormData(event.currentTarget as HTMLFormElement)
  busy.value = true
  error.value = ''
  try {
    const data = actionData(action, form)
    if (action === 'notice' && rule.value) {
      data.agreement = rule.value.agreement
      data.notice_rule_version = rule.value.version
    }
    operation = retryOperation(operation, { kind: action, data })
    await api(props.path + '/actions', requestJson({ operation_id: operation.id, kind: action, data }))
    if (!active()) return
    kind.value = undefined
    emit('saved')
  } catch (problem) {
    if (active()) {
      error.value = reportError(problem, () => emit('session-expired'))
      refreshNotice.value = action === 'notice' && problem instanceof ApiError && problem.status === 409
      if (refreshNotice.value) {
        noticeDraft.value = Object.fromEntries(fields.value.map(field => [field.name, String(form.get(field.name) ?? '')]))
      }
    }
  } finally {
    if (active()) busy.value = false
  }
}

function refreshRule() {
  error.value = ''
  refreshNotice.value = false
  reloadNotice()
}
</script>

<template>
  <UCard
    v-if="choices.length"
    as="section"
    aria-label="Record an action"
    :ui="{ header: 'px-4 py-3 sm:px-4', body: 'px-4 py-4 sm:px-4' }"
  >
    <template #header>
      <h3 class="font-semibold text-highlighted">
        Record an action
      </h3>
    </template>
    <UFormField label="Action">
      <USelect
        v-model="kind"
        aria-label="Action"
        class="w-full"
        :items="choices"
        placeholder="Choose an action"
        :disabled="busy"
      />
    </UFormField>

    <template v-if="selected === 'notice'">
      <p v-if="noticeSettings.kind === 'loading'" role="status" class="mt-4 text-sm text-muted">
        Loading the applicable notice rule…
      </p>
      <UAlert
        v-else-if="noticeSettings.kind === 'error'"
        :title="noticeSettings.message"
        color="error"
        variant="subtle"
        class="mt-4"
      >
        <template #actions>
          <UButton
            color="neutral"
            variant="outline"
            label="Retry loading notice rules"
            @click="refreshRule"
          />
        </template>
      </UAlert>
      <div v-else-if="noticeBlocked" class="mt-4 space-y-2">
        <p role="status" class="text-sm text-muted">
          {{ noticeBlocked }}
        </p>
        <NoticeRuleSummary v-if="rule" :rule="rule" />
      </div>
    </template>

    <form
      v-if="selected && canEnterAction"
      :key="selected"
      class="mt-4 space-y-4"
      :aria-label="actions[selected].label"
      @submit.prevent="save"
    >
      <section v-if="selected === 'notice' && rule" class="rounded-md border border-default p-3" aria-label="Applicable rule">
        <h4 class="mb-2 text-sm font-semibold text-highlighted">
          Applicable rule · Version {{ rule.version }}
        </h4>
        <NoticeRuleSummary :rule="rule" />
      </section>
      <fieldset class="min-w-0 space-y-4" :disabled="busy">
        <CaseActionField
          v-for="field in fields"
          :key="field.name"
          :field="field"
          :disabled="busy"
        />

        <CaseNoticeServiceFields
          v-if="selected === 'notice_dispatch' || selected === 'notice_receipt'"
          :kind="selected"
          :record="record"
          :copies="issuedCopies"
          :disabled="busy"
        />

        <template v-if="selected === 'quote'">
          <p class="text-sm text-muted">
            Enter credits as negative amounts. Use a decimal point and omit commas.
          </p>
          <fieldset v-for="(row, index) in quoteRows" :key="row" class="min-w-0 space-y-3 rounded-md border border-default px-3 pb-3">
            <legend class="px-1 text-sm font-medium">
              Line {{ index + 1 }}
            </legend>
            <CaseActionField :field="{ name: 'description', label: `Description for line ${index + 1}`, limit: 2000 }" :disabled="busy" />
            <CaseActionField :field="{ name: 'amount', label: `Amount for line ${index + 1}`, input: 'money' }" :disabled="busy" />
            <UButton
              v-if="quoteRows.length > 1"
              color="neutral"
              variant="outline"
              type="button"
              :aria-label="`Remove quote line ${index + 1}`"
              :disabled="busy"
              @click="quoteRows = quoteRows.filter(id => id !== row)"
            >
              Remove line
            </UButton>
          </fieldset>
          <UButton
            color="neutral"
            variant="outline"
            icon="i-lucide-plus"
            type="button"
            :disabled="busy || quoteRows.length >= 99"
            @click="addQuoteLine"
          >
            Add quote line
          </UButton>
        </template>

        <template v-if="selected === 'decision' && currentQuote">
          <fieldset v-for="(line, index) in currentQuote.data.lines" :key="index" class="min-w-0 space-y-3 rounded-md border border-default px-3 pb-3">
            <legend class="px-1 text-sm font-medium">
              Line {{ index + 1 }}
            </legend>
            <p class="wrap-anywhere">
              {{ line.description }}
            </p>
            <p class="text-sm text-muted">
              Proposed {{ formatDecimal(line.amount) }}
            </p>
            <CaseActionField
              :field="{
                name: 'accepted',
                label: `Accepted amount for line ${index + 1}`,
                input: 'money',
                value: currentDecision?.data.lines.find(item => item.line === index + 1)?.accepted ?? '0'
              }"
              :disabled="busy"
            />
            <CaseActionField
              :field="{
                name: 'disposition',
                label: `Disposition for line ${index + 1}`,
                options: dispositionChoices,
                value: currentDecision?.data.lines.find(item => item.line === index + 1)?.disposition ?? 'open'
              }"
              :disabled="busy"
            />
          </fieldset>
        </template>
      </fieldset>
      <p v-if="error" role="alert" class="text-sm text-error">
        {{ error }}
      </p>
      <div class="flex flex-wrap gap-2">
        <UButton type="submit" :loading="busy" :disabled="refreshNotice">
          Record action
        </UButton>
        <UButton
          v-if="refreshNotice"
          color="neutral"
          variant="outline"
          label="Refresh notice rule"
          @click="refreshRule"
        />
      </div>
    </form>
  </UCard>
</template>
