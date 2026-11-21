<script setup lang="ts">
import type { ActivityDay } from '~/types/overview'

const props = defineProps<{ activity: ActivityDay[] }>()
const date = new Intl.DateTimeFormat('en-ZA', { month: 'short', day: 'numeric', timeZone: 'UTC' })
const integer = new Intl.NumberFormat('en-ZA')

const series = computed(() => props.activity.map(day => ({
  date: date.format(new Date(day.day + 'T00:00:00Z')),
  observations: day.observations,
  cases: day.cases
})))
const total = computed(() => props.activity.reduce((sum, day) => sum + day.observations, 0))
const description = computed(() => `Change activity, last ${props.activity.length} days`)
</script>

<template>
  <UCard :ui="{ root: 'min-w-0 overflow-visible', body: 'p-0! overflow-hidden rounded-b-[inherit]' }">
    <template #header>
      <div class="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 class="text-xs text-muted uppercase mb-1.5">
            Change activity
          </h2>
          <p class="text-3xl text-highlighted font-semibold">
            {{ integer.format(total) }} <span class="text-sm font-normal text-muted">observations</span>
          </p>
        </div>
      </div>
    </template>

    <UChart
      type="area"
      curve="monotone"
      :data="series"
      index="date"
      :categories="[
        { key: 'observations', label: 'Observations', color: 'var(--ui-primary)' },
        { key: 'cases', label: 'Cases opened', color: 'var(--ui-info)' }
      ]"
      :x-axis="false"
      :y-axis="false"
      :grid="true"
      :format="(value: number) => integer.format(value)"
      :aspect-ratio="3"
      :initial-width="1152"
      class="-my-px"
      :aria-label="description"
      role="img"
    />

    <details class="border-t border-default p-3 text-sm text-muted">
      <summary class="cursor-pointer">
        Daily counts (UTC)
      </summary>
      <table class="mt-2 w-full text-left">
        <thead>
          <tr>
            <th scope="col">
              Date
            </th><th scope="col">
              Observations
            </th><th scope="col">
              Cases opened
            </th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="day in activity" :key="day.day">
            <th scope="row" class="py-1 font-normal">
              {{ day.day }}
            </th><td>{{ day.observations }}</td><td>{{ day.cases }}</td>
          </tr>
        </tbody>
      </table>
    </details>
  </UCard>
</template>
