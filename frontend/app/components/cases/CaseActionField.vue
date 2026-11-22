<script setup lang="ts">
import { computed } from 'vue'
import type { ActionField } from './action-fields'

const props = defineProps<{ field: ActionField, disabled?: boolean }>()
const items = computed(() => props.field.optional
  ? [{ value: '__none__', label: 'None' }, ...(props.field.options ?? [])]
  : props.field.options ?? [])
const amountPattern = '-?(0|[1-9][0-9]{0,11})([.][0-9]{1,2})?'
const timeHelp = computed(() => (
  props.field.input === 'timestamp'
    ? 'Use an explicit offset, for example 2026-04-10T17:00:00+02:00.'
    : props.field.input === 'datetime-local' ? 'Uses the time zone on this device.' : undefined
))
</script>

<template>
  <UFormField
    :label="field.label"
    :name="field.name"
    :required="!field.optional"
    :hint="field.optional ? 'Optional' : undefined"
    :help="timeHelp"
  >
    <USelect
      v-if="field.options"
      class="w-full"
      :name="field.name"
      :aria-label="field.label"
      :items="items"
      :default-value="field.value ?? (field.optional ? '__none__' : undefined)"
      :required="!field.optional"
      :disabled="disabled"
      :placeholder="`Choose ${field.label.toLowerCase()}`"
    />
    <UTextarea
      v-else-if="field.input === 'textarea'"
      class="w-full"
      :name="field.name"
      :aria-label="field.label"
      :default-value="field.value"
      :required="!field.optional"
      :disabled="disabled"
      :maxlength="field.limit"
      :rows="4"
    />
    <UInput
      v-else
      class="w-full"
      :name="field.name"
      :aria-label="field.label"
      :type="field.input === 'datetime-local' ? 'datetime-local' : 'text'"
      :default-value="field.value"
      :required="!field.optional"
      :readonly="field.readonly"
      :disabled="disabled"
      :maxlength="field.input === 'money' ? 16 : field.limit"
      :pattern="field.input === 'money' ? amountPattern : undefined"
      :title="field.input === 'money' ? 'Use up to twelve whole digits and two decimal places, without commas.' : undefined"
    />
  </UFormField>
</template>
