<script setup lang="ts">
import { activityPeriods, type ActivityDay, type ActivityPeriod } from '~/types/overview'

const props = defineProps<{ activity: ActivityDay[], loading: boolean }>()
const period = defineModel<ActivityPeriod>('period', { required: true })
const date = new Intl.DateTimeFormat('en-ZA', { month: 'short', day: 'numeric', timeZone: 'UTC' })
const integer = new Intl.NumberFormat('en-ZA')

const series = computed(() => props.activity.map(day => ({
  date: date.format(new Date(day.day + 'T00:00:00Z')),
  observations: day.observations,
  cases: day.cases
})))
const totals = computed(() => props.activity.reduce((sum, day) => ({
  observations: sum.observations + day.observations,
  cases: sum.cases + day.cases
}), { observations: 0, cases: 0 }))
const description = computed(() => `Change activity, last ${props.activity.length} days`)
</script>

<template>
  <UCard
    as="section"
    aria-labelledby="change-activity"
    :ui="{ root: 'min-w-0 overflow-visible', body: 'p-0! overflow-hidden rounded-b-[inherit]' }"
  >
    <template #header>
      <div class="space-y-3">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h2 id="change-activity" class="font-semibold text-highlighted">
            Change activity
          </h2>
          <UFieldGroup role="group" aria-label="Activity range" :aria-busy="loading">
            <UButton
              v-for="days in activityPeriods"
              :key="days"
              size="sm"
              :label="`${days} days`"
              color="neutral"
              :variant="period === days ? 'soft' : 'outline'"
              :aria-pressed="period === days"
              @click="period = days"
            />
          </UFieldGroup>
        </div>
        <dl class="flex flex-wrap items-center gap-x-5 gap-y-1.5 text-sm" :aria-busy="loading">
          <div class="flex items-center gap-1.5">
            <dt class="flex items-center gap-1.5 text-muted">
              <span class="size-2 rounded-full bg-primary" aria-hidden="true" />
              Observations
            </dt>
            <dd class="font-semibold text-highlighted tabular-nums">
              {{ integer.format(totals.observations) }}
            </dd>
          </div>
          <div class="flex items-center gap-1.5">
            <dt class="flex items-center gap-1.5 text-muted">
              <span class="size-2 rounded-full bg-info" aria-hidden="true" />
              Cases opened
            </dt>
            <dd class="font-semibold text-highlighted tabular-nums">
              {{ integer.format(totals.cases) }}
            </dd>
          </div>
        </dl>
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
      :legend="false"
      :grid="true"
      :format="(value: number) => integer.format(value)"
      :height="220"
      :initial-width="1152"
      class="-my-px"
      :aria-label="description"
      :aria-busy="loading"
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
