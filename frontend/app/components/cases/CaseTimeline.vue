<script setup lang="ts">
import { computed } from 'vue'
import { dispositions, eventTitle, formatDate, formatDecimal, moneyLabels, outcomes, type BankReceipt, type CaseEvent, type MoneyField } from './case-data'
import NoticeRuleSummary from './NoticeRuleSummary.vue'
import { formatNoticeDeadline } from './notice-rule'

const props = defineProps<{ events: CaseEvent[], receipts: BankReceipt[] }>()
const references = computed(() => new Map([
  ...props.events.map(event => [event.id, eventTitle(event)] as const),
  ...props.receipts.map(receipt => [receipt.id, 'Receipt ' + receipt.reference] as const)
]))
const referenceKeys = new Set(['notice', 'instruction', 'quote', 'predecessor', 'application', 'receipt', 'certificate', 'allocation'])
const amountKeys = new Set(['amount', 'cumulative', 'withheld', 'released'])
const eventLabels = {
  reference: 'Reference', agreement: 'Agreement', scope: 'Authorized scope', body: 'Notice text', due_at: 'Due',
  trigger_at: 'Trigger date and time', deadline_basis: 'Manual deadline basis',
  notice: 'Notice', instruction: 'Instruction', description: 'Work performed', completed: 'Completion',
  quote: 'Quote', reason: 'Reason', amount: 'Amount', cumulative: 'Cumulative certified',
  withheld: 'Retention withheld', released: 'Retention released', predecessor: 'Earlier certificate',
  application: 'Payment application', receipt: 'Cash receipt', certificate: 'Certificate', allocation: 'Allocation', outcome: 'Outcome'
}

function fieldValue(key: string, value: unknown) {
  const text = String(value)
  if (referenceKeys.has(key)) return references.value.get(text) ?? text
  if (amountKeys.has(key)) return formatDecimal(text)
  if (key === 'completed') return value === true ? 'Complete' : 'In progress'
  if (key === 'due_at') return formatDate(text)
  if (key === 'outcome') return outcomes.find(([candidate]) => candidate === value)?.[1] ?? text
  return text
}

function visibleFields(event: CaseEvent) {
  const data: Record<string, unknown> = event.data
  const content = Object.entries(eventLabels).flatMap(([key, label]) => data[key] == null
    ? []
    : [{
        id: key,
        label,
        value: key === 'due_at' && event.kind === 'notice' && event.data.notice_rule
          ? formatNoticeDeadline(String(data[key]))
          : fieldValue(key, data[key])
      }])
  for (const [key, value] of Object.entries(event.data.financial_snapshot ?? {})) {
    const label = ({ work_delta: 'Certified this period', certificate_credit_applied: 'Certificate credit applied' } as Record<string, string>)[key]
      ?? moneyLabels[key as MoneyField]
    if (label && value != null) content.push({ id: 'snapshot-' + key, label, value: formatDecimal(value) })
  }
  return content
}
</script>

<template>
  <UCard as="section" aria-label="Evidence timeline" :ui="{ header: 'px-4 py-3 sm:px-4', body: 'p-0 sm:p-0' }">
    <template #header>
      <h3 class="font-semibold text-highlighted">
        Evidence timeline
      </h3>
    </template>
    <p v-if="events.length === 0" class="p-4 text-sm text-muted">
      No actions have been recorded for this case.
    </p>
    <ol v-else class="divide-y divide-default">
      <li v-for="event in events" :key="event.id" class="px-4 py-3">
        <details>
          <summary class="cursor-pointer text-sm font-medium wrap-anywhere text-highlighted">
            <span>{{ eventTitle(event) }}</span>
            <time :datetime="event.recorded_at" class="ms-4 block text-xs font-normal text-muted">{{ formatDate(event.recorded_at) }}</time>
          </summary>
          <dl class="mt-3 space-y-2 text-sm">
            <div v-for="field in visibleFields(event)" :key="field.id" class="min-w-0">
              <dt class="text-xs text-muted">
                {{ field.label }}
              </dt>
              <dd class="wrap-anywhere whitespace-pre-wrap">
                {{ field.value }}
              </dd>
            </div>
          </dl>
          <section
            v-if="event.kind === 'notice' && event.data.notice_rule"
            class="mt-3 rounded-md border border-default p-3"
            aria-label="Recorded notice rule"
          >
            <h4 class="mb-2 text-sm font-semibold text-highlighted">
              Recorded rule · Version {{ event.data.notice_rule.version }}
            </h4>
            <NoticeRuleSummary :rule="event.data.notice_rule" />
          </section>
          <div v-if="event.kind === 'quote' || event.kind === 'decision'" class="mt-3 overflow-x-auto">
            <table v-if="event.kind === 'quote'" class="w-full min-w-48 text-left text-sm" aria-label="Quoted lines">
              <thead class="bg-elevated text-muted">
                <tr>
                  <th scope="col" class="px-2 py-1.5">
                    Description
                  </th><th scope="col" class="px-2 py-1.5">
                    Amount
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-default">
                <tr v-for="(line, index) in event.data.lines" :key="index">
                  <td class="px-2 py-1.5 wrap-anywhere">
                    {{ line.description }}
                  </td>
                  <td class="px-2 py-1.5 tabular-nums">
                    {{ formatDecimal(line.amount) }}
                  </td>
                </tr>
              </tbody>
            </table>
            <table v-else class="w-full min-w-48 text-left text-sm" aria-label="Decision by line">
              <thead class="bg-elevated text-muted">
                <tr>
                  <th scope="col" class="px-2 py-1.5">
                    Line
                  </th>
                  <th scope="col" class="px-2 py-1.5">
                    Accepted
                  </th>
                  <th scope="col" class="px-2 py-1.5">
                    Disposition
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-default">
                <tr v-for="line in event.data.lines" :key="line.line">
                  <td class="px-2 py-1.5">
                    {{ line.line }}
                  </td>
                  <td class="px-2 py-1.5 tabular-nums">
                    {{ formatDecimal(line.accepted) }}
                  </td>
                  <td class="px-2 py-1.5">
                    {{ dispositions.find(([key]) => key === line.disposition)?.[1] ?? line.disposition }}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="mt-3 text-xs wrap-anywhere text-muted">
            Recorded by {{ event.actor_id }}
          </p>
        </details>
      </li>
    </ol>
  </UCard>
</template>
