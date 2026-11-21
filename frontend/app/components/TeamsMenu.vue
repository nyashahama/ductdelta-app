<script setup lang="ts">
import type { DropdownMenuItem } from '@nuxt/ui'
import type { Project } from '~/utils/api'

const props = defineProps<{
  collapsed?: boolean
  project?: Project
  projects?: Project[]
}>()
const emit = defineEmits<{ select: [id: string] }>()
const items = computed<DropdownMenuItem[][]>(() => [[{
  type: 'label',
  label: 'Projects'
}, ...(props.projects ?? []).map(({ id, name }) => ({
  label: name,
  icon: id === props.project?.id ? 'i-lucide-check' : 'i-lucide-folder',
  onSelect: () => emit('select', id)
}))]])
</script>

<template>
  <UDropdownMenu
    :items="items"
    :content="{ align: 'center', collisionPadding: 12 }"
    :ui="{ content: collapsed ? 'w-48' : 'w-(--reka-dropdown-menu-trigger-width)' }"
  >
    <UButton
      aria-label="Select project"
      :disabled="!projects?.length"
      icon="i-lucide-triangle"
      :trailing-icon="collapsed ? undefined : 'i-lucide-chevrons-up-down'"
      color="neutral"
      variant="ghost"
      block
      :square="collapsed"
      class="data-[state=open]:bg-elevated"
      :class="{ 'py-2': !collapsed }"
      :ui="{ label: 'truncate', trailingIcon: 'text-dimmed' }"
    >
      <span v-if="!collapsed" class="min-w-0 text-left">
        <span class="block font-semibold text-highlighted">DuctDelta</span>
        <span class="block truncate text-xs text-muted">{{ project?.name ?? (projects ? 'Select a project' : 'Loading projects…') }}</span>
      </span>
    </UButton>
  </UDropdownMenu>
</template>
