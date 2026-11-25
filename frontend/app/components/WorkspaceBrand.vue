<script setup lang="ts">
import { workspaceMark } from '~/utils/brand'

defineProps<{ compact?: boolean }>()
</script>

<template>
  <div class="workspace-brand">
    <img
      :src="workspaceMark"
      width="32"
      height="32"
      alt=""
    >
    <span :class="{ 'sr-only': compact }">DuctDelta</span>
  </div>
</template>
