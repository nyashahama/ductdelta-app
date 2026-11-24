<script setup lang="ts">
import { ApiError, api, requestJson } from '~/utils/api'
import { useTimeoutFn } from '@vueuse/core'

const props = defineProps<{ invitation: string, savedKey?: string }>()
const emit = defineEmits<{ done: [], cancel: [] }>()
const { refreshSession, signInError, sessionCheckError, restoreSession } = useWorkspace()
const mode = ref<'sign_in' | 'company' | 'upgrade'>('sign_in')
const email = ref('')
const code = ref('')
const company = ref('')
const name = ref('')
const setupCode = ref('')
const legacyKey = ref('')
const registration = ref<'loading' | 'open' | 'code' | 'unavailable'>('loading')
const challenge = ref('')
const pending = ref(false)
const verified = ref(false)
const error = ref('')
const codeInput = ref<{ inputRef?: HTMLInputElement }>()
const resend = useTimeoutFn(() => {}, 60_000, { immediate: false })

const purpose = computed(() => props.invitation && mode.value !== 'upgrade' ? 'invite' : mode.value)
const title = computed(() => {
  if (challenge.value) return 'Enter your sign-in code'
  return {
    sign_in: 'Sign in to your workspace',
    company: 'Create your company',
    invite: 'Join the company',
    upgrade: 'Connect your email'
  }[purpose.value]
})

async function loadRegistration() {
  registration.value = 'loading'
  try {
    const policy = await api<{ setup_code_required: boolean }>('/api/company-registration')
    registration.value = policy.setup_code_required ? 'code' : 'open'
  } catch {
    registration.value = 'unavailable'
  }
}

function changeMode(next: typeof mode.value) {
  resend.stop()
  mode.value = next
  challenge.value = ''
  verified.value = false
  code.value = ''
  setupCode.value = ''
  legacyKey.value = next === 'upgrade' ? props.savedKey ?? '' : ''
  error.value = ''
  signInError.value = ''
  if (next === 'company') void loadRegistration()
}

watch(() => props.invitation, () => changeMode('sign_in'))

async function submit() {
  if (pending.value || sessionCheckError.value) return
  if (purpose.value === 'company' && ['loading', 'unavailable'].includes(registration.value)) return
  pending.value = true
  error.value = ''
  signInError.value = ''
  try {
    if (!challenge.value) {
      const additional = {
        sign_in: {},
        company: { company: company.value, name: name.value, setup_code: setupCode.value.trim() || undefined },
        invite: { token: props.invitation },
        upgrade: { key: legacyKey.value.trim(), token: props.invitation || undefined }
      }[purpose.value]
      const result = await api<{ id: string }>('/api/account/email-codes', requestJson({
        email: email.value.trim(), purpose: purpose.value, ...additional
      }))
      challenge.value = result.id
      resend.start()
      setupCode.value = ''
      legacyKey.value = ''
      await nextTick()
      codeInput.value?.inputRef?.focus()
      return
    }

    if (!verified.value) {
      await api('/api/account/email-codes/verify', requestJson({ id: challenge.value, code: code.value.trim() }))
      verified.value = true
      code.value = ''
    }
    await refreshSession()
    if (purpose.value === 'company') await navigateTo({ path: '/', query: { view: 'company' } }, { replace: true })
    emit('done')
  } catch (cause) {
    if (props.invitation && cause instanceof ApiError && cause.status === 404) {
      error.value = 'This invitation is unavailable. Check the invited email address or ask for a new invitation.'
    } else if (purpose.value === 'upgrade' && !challenge.value && cause instanceof ApiError && cause.status === 401) {
      error.value = 'This key is unavailable. Check your access or recovery key.'
    } else {
      error.value = cause instanceof ApiError ? cause.message : 'Could not reach DuctDelta. Try again.'
    }
  } finally {
    pending.value = false
  }
}
</script>

<template>
  <main class="min-h-dvh grid place-items-center p-4">
    <UCard class="w-full max-w-md" aria-labelledby="workspace-gate-title">
      <template #header>
        <div class="flex items-center gap-2 text-highlighted font-semibold">
          <UIcon name="i-lucide-triangle" class="size-5 text-primary" />
          DuctDelta
        </div>
      </template>

      <h1 id="workspace-gate-title" class="text-2xl font-semibold text-highlighted">
        {{ title }}
      </h1>

      <UAlert
        v-if="sessionCheckError"
        class="mt-4"
        color="error"
        variant="subtle"
        :title="sessionCheckError"
      >
        <template #actions>
          <UButton
            label="Check session again"
            color="neutral"
            variant="outline"
            @click="restoreSession"
          />
        </template>
      </UAlert>
      <form v-else class="mt-4 flex flex-col gap-3" @submit.prevent="submit">
        <template v-if="challenge">
          <p class="text-muted" role="status">
            Check {{ email }} for an eight-digit code. It expires 10 minutes after you request it.
          </p>
          <UFormField
            v-if="!verified"
            label="Sign-in code"
            name="code"
            required
          >
            <UInput
              ref="codeInput"
              v-model="code"
              autocomplete="one-time-code"
              inputmode="numeric"
              pattern="[0-9]{8}"
              maxlength="8"
              required
              :readonly="pending"
              class="w-full"
            />
          </UFormField>
        </template>
        <template v-else>
          <p v-if="purpose === 'invite'" class="text-muted">
            Use the email address this invitation was sent to, or your work email if you received a private link.
          </p>
          <p v-if="purpose === 'upgrade'" class="text-muted">
            Use your existing access or recovery key once to connect your email.
          </p>
          <template v-if="purpose === 'company'">
            <UFormField label="Company name" name="company" required>
              <UInput
                v-model="company"
                autocomplete="organization"
                maxlength="120"
                required
                :readonly="pending"
                class="w-full"
              />
            </UFormField>
            <UFormField label="Your name" name="name" required>
              <UInput
                v-model="name"
                autocomplete="name"
                maxlength="120"
                required
                :readonly="pending"
                class="w-full"
              />
            </UFormField>
          </template>
          <UFormField label="Email address" name="email" required>
            <UInput
              v-model="email"
              type="email"
              autocomplete="email"
              maxlength="254"
              required
              :readonly="pending"
              class="w-full"
            />
          </UFormField>
          <UFormField
            v-if="purpose === 'company' && registration === 'code'"
            label="Company setup code"
            name="setup-code"
            required
          >
            <UInput
              v-model="setupCode"
              type="password"
              autocomplete="off"
              maxlength="64"
              required
              :readonly="pending"
              class="w-full"
            />
          </UFormField>
          <UFormField
            v-if="purpose === 'upgrade'"
            label="Access or recovery key"
            name="existing-key"
            required
          >
            <UInput
              v-model="legacyKey"
              type="password"
              autocomplete="current-password"
              maxlength="64"
              required
              :readonly="pending"
              class="w-full"
            />
          </UFormField>
          <UAlert
            v-if="purpose === 'company' && registration === 'unavailable'"
            color="error"
            variant="subtle"
            title="Could not check company setup."
          >
            <template #actions>
              <UButton
                label="Check again"
                color="neutral"
                variant="outline"
                @click="loadRegistration"
              />
            </template>
          </UAlert>
        </template>
        <UButton
          type="submit"
          :label="challenge ? 'Continue' : 'Email me a code'"
          block
          :loading="pending"
          :disabled="purpose === 'company' && ['loading', 'unavailable'].includes(registration)"
        />
      </form>

      <UAlert
        v-if="error || signInError"
        class="mt-4"
        role="alert"
        color="error"
        variant="subtle"
        :title="error || signInError"
      />

      <div class="mt-4 flex flex-wrap gap-2 justify-between">
        <UButton
          v-if="challenge && !verified"
          label="Request another code"
          color="neutral"
          variant="link"
          :disabled="pending || resend.isPending.value"
          @click="changeMode(mode)"
        />
        <UButton
          v-if="invitation && !challenge"
          :label="purpose === 'upgrade' ? 'Back to invitation' : 'Use an existing key'"
          color="neutral"
          variant="link"
          :disabled="pending"
          @click="changeMode(purpose === 'upgrade' ? 'sign_in' : 'upgrade')"
        />
        <UButton
          v-if="invitation"
          label="Cancel invitation"
          color="neutral"
          variant="link"
          :disabled="pending"
          @click="emit('cancel')"
        />
        <template v-else-if="purpose === 'sign_in' && !challenge">
          <UButton
            label="Create a company"
            color="neutral"
            variant="link"
            :disabled="pending"
            @click="changeMode('company')"
          />
          <UButton
            label="Use an existing key"
            color="neutral"
            variant="link"
            :disabled="pending"
            @click="changeMode('upgrade')"
          />
          <UButton
            label="About DuctDelta"
            color="neutral"
            variant="link"
            to="/product/"
            external
          />
        </template>
        <UButton
          v-else-if="!verified"
          label="Back to sign in"
          color="neutral"
          variant="link"
          :disabled="pending"
          @click="changeMode('sign_in')"
        />
      </div>
    </UCard>
  </main>
</template>
