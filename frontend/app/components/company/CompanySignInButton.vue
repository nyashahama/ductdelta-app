<script setup lang="ts">
import { ApiError, api, requestJson } from '~/utils/api'

const props = defineProps<{ company: string, name?: string }>()
const pending = ref(false)
const error = ref('')

async function start() {
  if (pending.value) return
  pending.value = true
  error.value = ''
  try {
    const { url } = await api<{ url: string }>('/api/account/sso/start', requestJson({ company: props.company }))
    window.location.assign(url)
  } catch (cause) {
    error.value = cause instanceof ApiError ? cause.message : 'Could not open company sign-in. Try again.'
    pending.value = false
  }
}
</script>

<template>
  <div class="space-y-2">
    <UButton
      :label="name ? 'Sign in with Microsoft for ' + name : 'Sign in with Microsoft'"
      color="neutral"
      variant="outline"
      :loading="pending"
      @click="start"
    />
    <p v-if="error" class="text-error text-sm" role="alert">
      {{ error }}
    </p>
  </div>
</template>
