<script setup lang="ts">
import { formatDecimal } from '~/components/cases/case-data'
import type { Overview } from '~/types/overview'

const props = defineProps<{ data: Overview }>()
const integer = new Intl.NumberFormat('en-ZA')

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
        value: 'R ' + formatDecimal(props.data.financial.outstanding),
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
  <dl aria-label="Project totals" class="grid shrink-0 grid-cols-2 gap-px overflow-hidden rounded-xl border border-default bg-border lg:grid-cols-4">
    <div
      v-for="stat in stats"
      :key="stat.key"
      :data-metric="stat.key"
      class="min-w-0 bg-default px-3 py-3.5 sm:px-5"
    >
      <dt class="flex items-center gap-2 text-xs font-medium text-toned">
        <UIcon :name="stat.icon" class="size-4 shrink-0 text-primary" aria-hidden="true" />
        {{ stat.title }}
      </dt>
      <dd class="mt-1.5 text-[1.625rem] leading-none font-semibold tracking-tight wrap-anywhere text-highlighted tabular-nums">
        {{ stat.value }}
      </dd>
      <dd v-if="stat.description" class="mt-1 text-xs text-muted">
        {{ stat.description }}
      </dd>
    </div>
  </dl>
</template>
