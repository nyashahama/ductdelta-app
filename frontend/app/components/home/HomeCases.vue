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
  <section aria-labelledby="recent-open-cases">
    <div class="mb-3 flex flex-wrap justify-between items-center gap-2">
      <h2 id="recent-open-cases" class="font-semibold text-highlighted">
        Recent open cases
      </h2>
      <UButton
        variant="ghost"
        color="neutral"
        trailing-icon="i-lucide-arrow-right"
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
        base: 'table-fixed border-separate border-spacing-0',
        thead: '[&>tr]:bg-elevated/50 [&>tr]:after:content-none',
        tbody: '[&>tr]:last:[&>td]:border-b-0',
        th: 'first:rounded-l-lg last:rounded-r-lg border-y border-default first:border-l last:border-r whitespace-normal max-sm:first:w-3/5 max-sm:nth-3:hidden max-sm:last:hidden',
        td: 'border-b border-default wrap-anywhere whitespace-normal max-sm:nth-3:hidden max-sm:last:hidden'
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
