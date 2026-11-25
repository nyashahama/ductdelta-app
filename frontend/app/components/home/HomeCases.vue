<script setup lang="ts">
import type { TableColumn } from '@nuxt/ui'
import { formatDeadline, type RecentCase } from '~/types/overview'

defineProps<{ cases: RecentCase[] }>()
const emit = defineEmits<{ open: [id: string], register: [] }>()

const columns: TableColumn<RecentCase>[] = [
  { accessorKey: 'title', header: 'Change case' },
  { accessorKey: 'has_instruction', header: 'Written instruction' },
  { accessorKey: 'notice_due_at', header: 'Next notice deadline' },
  { accessorKey: 'recorded_at', header: 'Recorded' }
]

const recorded = new Intl.DateTimeFormat('en-ZA', { dateStyle: 'medium', timeZone: 'UTC' })
</script>

<template>
  <section class="workspace-panel" aria-labelledby="recent-open-cases">
    <div class="flex flex-wrap justify-between items-center gap-2 px-4 py-3 sm:px-5">
      <h2 id="recent-open-cases" class="text-base font-semibold text-highlighted">
        Recent open cases
      </h2>
      <UButton
        variant="link"
        label="View case register"
        @click="emit('register')"
      />
    </div>
    <UTable
      :data="cases"
      :columns="columns"
      class="shrink-0"
      empty="There are no open change cases on this project."
      :ui="{
        base: 'table-fixed',
        thead: '[&>tr]:bg-muted [&>tr]:after:content-none',
        th: 'whitespace-normal first:w-2/5 max-sm:first:w-3/5 max-sm:nth-3:hidden max-sm:last:hidden',
        td: 'wrap-anywhere whitespace-normal max-sm:nth-3:hidden max-sm:last:hidden'
      }"
    >
      <template #title-cell="{ row }">
        <UButton
          color="neutral"
          variant="link"
          class="p-0 text-left justify-start whitespace-normal"
          :label="row.original.title"
          @click="emit('open', row.original.id)"
        />
        <p v-if="row.original.notice_due_at" class="mt-1 text-xs text-muted sm:hidden">
          Notice due {{ formatDeadline(row.original.notice_due_at) }}
        </p>
      </template>
      <template #has_instruction-cell="{ row }">
        <UBadge :color="row.original.has_instruction ? 'success' : 'warning'" variant="subtle">
          {{ row.original.has_instruction ? 'On file' : 'Awaiting' }}
        </UBadge>
      </template>
      <template #notice_due_at-cell="{ row }">
        {{ row.original.notice_due_at ? formatDeadline(row.original.notice_due_at) : '—' }}
      </template>
      <template #recorded_at-cell="{ row }">
        {{ recorded.format(new Date(row.original.recorded_at)) }}
      </template>
    </UTable>
  </section>
</template>
