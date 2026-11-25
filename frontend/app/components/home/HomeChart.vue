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
  <section class="workspace-panel" aria-labelledby="change-activity-heading">
    <header class="flex flex-wrap items-start justify-between gap-3 px-4 py-3 sm:px-5">
      <div>
        <h2 id="change-activity-heading" class="text-base font-semibold text-highlighted">
          Change activity
        </h2>
        <p class="mt-1 text-2xl text-highlighted font-semibold">
          {{ integer.format(total) }} <span class="text-sm font-normal text-muted">observations</span>
        </p>
      </div>
      <slot name="controls" />
    </header>

    <UChart
      type="area"
      curve="monotone"
      :data="series"
      index="date"
      :categories="[
        { key: 'observations', label: 'Observations', color: 'var(--ui-primary)' },
        { key: 'cases', label: 'Cases opened', color: 'var(--workspace-activity-cases)' }
      ]"
      :x-axis="false"
      :y-axis="false"
      :grid="true"
      :format="(value: number) => integer.format(value)"
      :aspect-ratio="2.7"
      :initial-width="448"
      class="border-t border-default"
      :aria-label="description"
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
  </section>
</template>
