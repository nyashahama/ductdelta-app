<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { api, reportError, requestJson } from '../../utils/api'
import { actionFields, dispositionChoices } from './action-fields'
import { actionData, actions, availableActions, eventsOf, formatDecimal, retryOperation, type ActionKind, type CaseRecord, type Operation } from './case-data'
import CaseActionField from './CaseActionField.vue'
import { useActiveScope } from './useCaseResource'

const props = defineProps<{ record: CaseRecord, permission: 'read' | 'capture', path: string }>()
const emit = defineEmits<{ saved: [], 'session-expired': [] }>()
const kind = ref<ActionKind>()
const error = ref('')
const busy = ref(false)
const active = useActiveScope()
const available = computed(() => availableActions(props.record, props.permission))
const choices = computed(() => available.value.map(value => ({ label: actions[value].label, value })))
const selected = computed(() => kind.value && available.value.includes(kind.value) ? kind.value : undefined)
const fields = computed(() => selected.value ? actionFields(selected.value, props.record) : [])
const quoteRows = ref([1])
let nextRow = 2
let operation: Operation | null = null

const currentQuote = computed(() => eventsOf(props.record, 'quote').at(-1))
const currentDecision = computed(() => eventsOf(props.record, 'decision').reverse().find(event => event.data.quote === currentQuote.value?.id))

watch(kind, () => {
  operation = null
  error.value = ''
  quoteRows.value = [1]
  nextRow = 2
})

function addQuoteLine() {
  quoteRows.value.push(nextRow++)
}

async function save(event: SubmitEvent) {
  const action = selected.value
  if (!action || busy.value) return
  const form = new FormData(event.currentTarget as HTMLFormElement)
  busy.value = true
  error.value = ''
  try {
    const data = actionData(action, form)
    operation = retryOperation(operation, { kind: action, data })
    await api(props.path + '/actions', requestJson({ operation_id: operation.id, kind: action, data }))
    if (!active()) return
    kind.value = undefined
    emit('saved')
  } catch (problem) {
    if (active()) error.value = reportError(problem, () => emit('session-expired'))
  } finally {
    if (active()) busy.value = false
  }
}
</script>

<template>
  <UCard v-if="choices.length" as="section" aria-label="Record an action" :ui="{ header: 'px-4 py-3 sm:px-4', body: 'px-4 py-4 sm:px-4' }">
    <template #header>
      <h3 class="font-semibold text-highlighted">
        Record an action
      </h3>
    </template>
    <UFormField label="Action">
      <USelect v-model="kind" aria-label="Action" class="w-full" :items="choices" placeholder="Choose an action" :disabled="busy" />
    </UFormField>

    <form v-if="selected" :key="selected" class="mt-4 space-y-4" :aria-label="actions[selected].label" @submit.prevent="save">
      <fieldset class="min-w-0 space-y-4" :disabled="busy">
        <CaseActionField v-for="field in fields" :key="field.name" :field="field" :disabled="busy" />

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
                name: 'accepted', label: `Accepted amount for line ${index + 1}`, input: 'money',
                value: currentDecision?.data.lines.find(item => item.line === index + 1)?.accepted ?? '0'
              }"
              :disabled="busy"
            />
            <CaseActionField
              :field="{
                name: 'disposition', label: `Disposition for line ${index + 1}`, options: dispositionChoices,
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
      <UButton type="submit" :loading="busy">
        Record action
      </UButton>
    </form>
  </UCard>
</template>
