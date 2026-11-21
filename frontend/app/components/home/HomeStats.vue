<script setup lang="ts">
import type { Overview } from '~/types/overview'

const props = defineProps<{ data: Overview }>()
const integer = new Intl.NumberFormat('en-ZA')

function money(value: string) {
  const [whole, decimal] = value.split('.')
  return 'R ' + (whole ?? '0').replace(/\B(?=(\d{3})+(?!\d))/g, ',') + (decimal ? '.' + decimal : '')
}

const stats = computed(() => [
  {
    key: 'open-cases',
    title: 'Open cases',
    icon: 'i-lucide-folders',
    value: integer.format(props.data.open_cases)
  },
  {
    key: 'without-instruction',
    title: 'Without instruction',
    icon: 'i-lucide-file-warning',
    value: integer.format(props.data.without_instruction)
  },
  {
    key: 'notices-due',
    title: 'Notices due',
    icon: 'i-lucide-calendar-clock',
    value: integer.format(props.data.notices_due),
    description: 'Overdue or due within 7 days'
  },
  props.data.financial
    ? {
        key: 'outstanding',
        title: 'Net certified balance',
        icon: 'i-lucide-banknote',
        value: money(props.data.financial.outstanding),
        description: 'Receivables less credits, excl. VAT'
      }
    : {
        key: 'observations',
        title: 'Observations',
        icon: 'i-lucide-clipboard-list',
        value: integer.format(props.data.observations)
      }
])
</script>

<template>
  <UPageGrid class="grid-cols-2 gap-3 lg:grid-cols-4 lg:gap-px">
    <UPageCard
      v-for="stat in stats"
      :key="stat.key"
      :data-metric="stat.key"
      :icon="stat.icon"
      :title="stat.title"
      variant="subtle"
      :ui="{
        container: 'gap-y-1.5 p-3 sm:p-6',
        wrapper: 'items-start',
        leading: 'p-2.5 rounded-full bg-primary/10 ring ring-inset ring-primary/25 flex-col',
        title: 'font-normal text-muted text-xs uppercase'
      }"
      class="lg:rounded-none first:rounded-l-lg last:rounded-r-lg"
    >
      <strong class="text-xl sm:text-2xl font-semibold text-highlighted break-words tabular-nums">
        {{ stat.value }}
      </strong>
      <p v-if="stat.description" class="text-xs text-muted">
        {{ stat.description }}
      </p>
    </UPageCard>
  </UPageGrid>
</template>
