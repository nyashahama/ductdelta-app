<script setup lang="ts">
import type { DropdownMenuItem } from '@nuxt/ui'

const props = defineProps<{
  collapsed?: boolean
  name: string
  signing: boolean
}>()
const emit = defineEmits<{ 'open-sessions': [], 'sign-out': [] }>()
const colorMode = useColorMode()

const items = computed<DropdownMenuItem[][]>(() => [[{
  type: 'label',
  label: props.name
}], [{
  label: 'Appearance',
  icon: 'i-lucide-sun-moon',
  children: ['System', 'Light', 'Dark'].map(label => ({
    label,
    type: 'checkbox',
    checked: colorMode.preference === label.toLowerCase(),
    onSelect: () => { colorMode.preference = label.toLowerCase() }
  }))
}], [{
  label: 'Account sessions',
  icon: 'i-lucide-monitor',
  to: { path: '/', query: { view: 'sessions' } },
  onSelect: () => emit('open-sessions')
}], [{
  label: 'Sign out',
  icon: 'i-lucide-log-out',
  disabled: props.signing,
  onSelect: () => emit('sign-out')
}]])
</script>

<template>
  <UDropdownMenu
    :items="items"
    :content="{ align: 'center', collisionPadding: 12 }"
    :ui="{ content: collapsed ? 'w-48' : 'w-(--reka-dropdown-menu-trigger-width)' }"
  >
    <UButton
      :aria-label="`Account menu, ${name}`"
      :avatar="{ alt: name, size: '2xs' }"
      :label="collapsed ? undefined : name"
      :trailing-icon="collapsed ? undefined : 'i-lucide-chevrons-up-down'"
      color="neutral"
      variant="ghost"
      block
      :square="collapsed"
      class="data-[state=open]:bg-elevated"
      :ui="{ label: 'truncate', trailingIcon: 'text-dimmed' }"
    />
  </UDropdownMenu>
</template>
