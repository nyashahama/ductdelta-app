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
  <dl class="workspace-metrics" aria-label="Project summary">
    <div
      v-for="stat in stats"
      :key="stat.key"
      :data-metric="stat.key"
      class="workspace-panel workspace-metric"
    >
      <dt class="workspace-metric-heading text-sm font-medium text-muted">
        {{ stat.title }}
        <span class="workspace-metric-icon" aria-hidden="true">
          <UIcon :name="stat.icon" class="size-4" />
        </span>
      </dt>
      <dd>
        <strong class="workspace-metric-value">{{ stat.value }}</strong>
        <p v-if="stat.description" class="mt-0.5 text-xs text-muted">
          {{ stat.description }}
        </p>
      </dd>
    </div>
  </dl>
</template>
