<script setup lang="ts">
import { computed } from 'vue'
import { formatDecimal, moneyLabels, type FinancialPosition, type MoneyField } from './case-data'

const props = defineProps<{ value: FinancialPosition }>()
const rows = computed(() => (Object.entries(moneyLabels) as [MoneyField, string][]).flatMap(([key, label]) => {
  const amount = props.value[key]
  return key === 'unallocated' && amount == null ? [] : [{ key, label, amount }]
}))
</script>

<template>
  <UCard as="section" aria-label="Financial position" :ui="{ header: 'px-4 py-3 sm:px-4', body: 'p-0 sm:p-0' }">
    <template #header>
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h3 class="font-semibold text-highlighted">
          Financial position
        </h3>
        <UBadge color="neutral" variant="subtle">
          {{ value.currency }}{{ value.basis === 'excl_vat' ? ' · Excl. VAT' : '' }}
        </UBadge>
      </div>
    </template>

    <p v-if="value.quote_awaiting_decision" class="border-b border-default px-4 py-3 text-sm text-warning">
      The latest quote is awaiting a decision.
    </p>
    <dl class="grid grid-cols-2 gap-px bg-border md:grid-cols-3">
      <div
        v-for="row in rows"
        :key="row.key"
        class="min-w-0 space-y-0.5 px-4 py-3 wrap-anywhere"
        :class="row.key === 'outstanding' ? 'bg-elevated' : 'bg-default'"
      >
        <dt class="text-xs text-muted">
          {{ row.label }}
        </dt>
        <dd v-if="row.amount != null" class="font-semibold tabular-nums text-highlighted">
          {{ formatDecimal(row.amount) }}
        </dd>
        <dd v-else class="text-sm text-muted">
          Not recorded
        </dd>
      </div>
    </dl>
  </UCard>
</template>
