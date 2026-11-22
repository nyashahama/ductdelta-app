<script setup lang="ts">
import { computed } from 'vue'
import { describeDeadline, type NoticeRule } from './notice-rule'

const props = defineProps<{ rule: NoticeRule }>()
const fields = computed(() => [
  { label: 'Agreement and clause', value: `${props.rule.agreement} · ${props.rule.clause}` },
  { label: 'Issuing authority', value: `${props.rule.issuer_name} · ${props.rule.authority}` },
  { label: 'Recipient', value: props.rule.recipient },
  { label: 'Service method', value: props.rule.service_method },
  { label: 'Trigger event', value: props.rule.trigger },
  { label: 'Deadline rule', value: describeDeadline(props.rule) },
  { label: 'Contract time zone', value: props.rule.timezone }
])
</script>

<template>
  <dl class="grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
    <div v-for="field in fields" :key="field.label" class="min-w-0">
      <dt class="text-xs text-muted">
        {{ field.label }}
      </dt>
      <dd class="wrap-anywhere whitespace-pre-wrap">
        {{ field.value }}
      </dd>
    </div>
  </dl>
</template>
