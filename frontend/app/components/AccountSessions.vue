<script setup lang="ts">
import { api, reportError } from '~/utils/api'

type AccountSession = {
  id: string
  created_at: string | null
  expires_at: string
  current: boolean
}

const path = '/api/account/sessions'
const { expire } = useWorkspace()
const sessions = shallowRef<AccountSession[]>()
const selection = ref<AccountSession | 'others'>()
const loading = ref(true)
const saving = ref(false)
const listError = ref('')
const actionError = ref('')
const receipt = ref('')
const dateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'medium' })

function label(session: AccountSession) {
  return 'Session ' + session.id.slice(0, 8)
}

function formatDate(value: string) {
  return dateFormat.format(new Date(value))
}

async function load() {
  loading.value = true
  listError.value = ''
  try {
    sessions.value = await api<AccountSession[]>(path)
  } catch (cause) {
    sessions.value = undefined
    listError.value = reportError(cause, expire)
  } finally {
    loading.value = false
  }
}

function choose(target: AccountSession | 'others') {
  selection.value = target
  actionError.value = ''
  receipt.value = ''
}

async function revoke() {
  const target = selection.value
  if (!target || saving.value) return
  saving.value = true
  actionError.value = ''
  try {
    await api(target === 'others' ? path : path + '/' + target.id, { method: 'DELETE' })
    selection.value = undefined
    receipt.value = target === 'others' ? 'Other sessions signed out.' : 'Session signed out.'
    await load()
  } catch (cause) {
    actionError.value = reportError(cause, expire)
    await load()
  } finally {
    saving.value = false
  }
}

onMounted(load)
</script>

<template>
  <UCard class="w-full max-w-3xl">
    <template #header>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="space-y-1">
          <h2 class="text-lg font-semibold text-highlighted">
            Active sessions
          </h2>
          <p class="text-sm text-muted">
            Review where your account is signed in across all companies.
          </p>
        </div>
        <UButton
          v-if="sessions?.some(session => !session.current)"
          label="Sign out all other sessions"
          color="neutral"
          variant="outline"
          :disabled="loading || saving"
          @click="choose('others')"
        />
      </div>
    </template>

    <p v-if="receipt" class="mb-3 text-sm text-success" role="status">
      {{ receipt }}
    </p>
    <UAlert
      v-if="listError"
      role="alert"
      color="error"
      variant="subtle"
      :title="listError"
    >
      <template #actions>
        <UButton
          label="Retry loading sessions"
          color="neutral"
          variant="outline"
          @click="load"
        />
      </template>
    </UAlert>
    <p v-else-if="loading" class="text-sm text-muted" role="status">
      Loading sessions…
    </p>
    <ul v-else class="divide-y divide-default">
      <li v-for="session in sessions" :key="session.id" class="flex flex-wrap items-center justify-between gap-3 py-3">
        <div class="space-y-1">
          <div class="flex flex-wrap items-center gap-2">
            <p class="font-medium text-highlighted">
              {{ label(session) }}
            </p>
            <UBadge v-if="session.current" color="success" variant="subtle">
              Current session
            </UBadge>
          </div>
          <p class="text-sm text-muted">
            {{ session.created_at ? 'Signed in ' + formatDate(session.created_at) : 'Sign-in time unavailable' }}
          </p>
          <p class="text-sm text-muted">
            Expires {{ formatDate(session.expires_at) }}
          </p>
        </div>
        <UButton
          v-if="!session.current"
          label="Sign out"
          color="neutral"
          variant="outline"
          :disabled="saving"
          @click="choose(session)"
        />
      </li>
    </ul>
  </UCard>

  <UModal
    :open="Boolean(selection)"
    :dismissible="!saving"
    :title="selection === 'others' ? 'Sign out all other sessions?' : 'Sign out this session?'"
    :description="selection === 'others' ? 'Your current session will stay signed in.' : selection ? label(selection) : undefined"
    @update:open="open => { if (!open && !saving) selection = undefined }"
  >
    <template #body>
      <UAlert
        v-if="actionError"
        role="alert"
        color="error"
        variant="subtle"
        class="mb-3"
        :title="actionError"
      />
      <div class="flex flex-wrap justify-end gap-2">
        <UButton
          label="Cancel"
          color="neutral"
          variant="outline"
          :disabled="saving"
          @click="selection = undefined"
        />
        <UButton
          label="Confirm sign-out"
          color="error"
          :loading="saving"
          @click="revoke"
        />
      </div>
    </template>
  </UModal>
</template>
