<script setup lang="ts">
import CompanySignInButton from '~/components/company/CompanySignInButton.vue'
import { api, reportError, requestJson } from '~/utils/api'

type Security = { email: string | null, has_recovery_code: boolean }
type Company = { id: string, name: string }

const route = useRoute()
const { expire } = useWorkspace()
const security = ref<Security>()
const companies = ref<Company[]>([])
const recoveryCode = ref('')
const replacing = ref(false)
const pending = ref(false)
const error = ref('')
const copied = ref(false)

async function load() {
  error.value = ''
  try {
    const [current, workAccounts] = await Promise.all([
      api<Security>('/api/account/security'),
      api<Company[]>('/api/account/sso/companies')
    ])
    security.value = current
    companies.value = workAccounts
  } catch (cause) {
    error.value = reportError(cause, expire)
  }
}

async function generate() {
  if (pending.value) return
  if (security.value?.has_recovery_code && !replacing.value) {
    replacing.value = true
    return
  }
  pending.value = true
  error.value = ''
  copied.value = false
  try {
    const result = await api<{ code: string }>('/api/account/security/recovery-code', requestJson({}))
    recoveryCode.value = result.code
    if (security.value) security.value.has_recovery_code = true
  } catch (cause) {
    error.value = reportError(cause, expire)
  } finally {
    pending.value = false
    replacing.value = false
  }
}

async function copyCode() {
  try {
    await navigator.clipboard.writeText(recoveryCode.value)
    copied.value = true
  } catch {
    error.value = 'Select and copy the code from the field.'
  }
}

onMounted(load)
</script>

<template>
  <div class="max-w-2xl space-y-4">
    <UAlert
      v-if="route.query.sso_error"
      color="error"
      variant="subtle"
      title="Company sign-in failed. Check with your company administrator."
    />
    <UAlert
      v-if="error"
      color="error"
      variant="subtle"
      :title="error"
    />
    <UButton
      v-if="error && !security"
      label="Try again"
      color="neutral"
      variant="outline"
      @click="load"
    />
    <p v-else-if="!security" class="text-muted" role="status">
      Loading account security…
    </p>
    <template v-else>
      <UCard v-if="security.email" class="space-y-3">
        <template #header>
          <h2 class="font-semibold">
            Sign-in email and recovery
          </h2>
        </template>
        <p class="wrap-anywhere">
          {{ security.email }}
        </p>
        <p class="mt-3 text-muted">
          Keep a recovery code somewhere outside your email. You can use it once to verify a new sign-in address.
        </p>
        <div v-if="recoveryCode" class="mt-3 space-y-2">
          <UFormField label="Account recovery code" name="recovery-code">
            <UInput
              :model-value="recoveryCode"
              readonly
              autocomplete="off"
              class="w-full font-mono"
            />
          </UFormField>
          <UButton
            label="Copy recovery code"
            color="neutral"
            variant="outline"
            @click="copyCode"
          />
          <p v-if="copied" class="text-muted" role="status">
            Copied.
          </p>
        </div>
        <p v-else-if="replacing" class="mt-3" role="status">
          Replacing the code invalidates the one you saved.
        </p>
        <div class="mt-3 flex flex-wrap gap-2">
          <UButton
            :label="replacing ? 'Replace recovery code' : security.has_recovery_code ? 'Generate a new recovery code' : 'Generate recovery code'"
            :loading="pending"
            @click="generate"
          />
          <UButton
            v-if="security.has_recovery_code"
            label="Change sign-in email"
            color="neutral"
            variant="outline"
            :to="{ path: '/', query: { view: 'security', recover: '1' } }"
          />
        </div>
      </UCard>
      <UCard v-if="companies.length">
        <template #header>
          <h2 class="font-semibold">
            Company sign-in
          </h2>
        </template>
        <ul class="space-y-3">
          <li v-for="company in companies" :key="company.id">
            <CompanySignInButton :company="company.id" :name="company.name" />
          </li>
        </ul>
      </UCard>
      <p v-if="!security.email && !companies.length" class="text-muted">
        Connect an email address to manage account recovery.
      </p>
    </template>
  </div>
</template>
