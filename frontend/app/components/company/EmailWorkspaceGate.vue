<script setup lang="ts">
import { ApiError, api, requestJson } from '~/utils/api'
import { useTimeoutFn } from '@vueuse/core'
import CompanySignInButton from '~/components/company/CompanySignInButton.vue'
import WorkspaceEntryShell from '~/components/company/WorkspaceEntryShell.vue'

const props = defineProps<{ invitation: string, savedKey?: string, recovery?: boolean }>()
const emit = defineEmits<{ done: [], cancel: [] }>()
const { refreshSession, signInError, sessionCheckError, restoreSession } = useWorkspace()
type Mode = 'sign_in' | 'company' | 'upgrade' | 'recover'
type PendingChallenge = { id: string, email: string, mode: Mode, invitationDigest: string, requestedAt: number }
const challengeStorage = 'ductdelta-pending-email-code'
const resendInterval = 60_000
const codeLifetime = 600_000
const mode = ref<Mode>(props.recovery ? 'recover' : 'sign_in')
const route = useRoute()
const ssoCompany = computed(() => typeof route.query.sso === 'string' && /^[a-f0-9-]{36}$/i.test(route.query.sso)
  ? route.query.sso
  : '')
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
const resendDelay = ref(resendInterval)
const resend = useTimeoutFn(() => {}, resendDelay, { immediate: false })

const purpose = computed(() => props.invitation && mode.value !== 'upgrade' ? 'invite' : mode.value)
const title = computed(() => {
  if (challenge.value) return 'Enter your sign-in code'
  return {
    sign_in: 'Sign in to your workspace',
    company: 'Create your company',
    invite: 'Join the company',
    upgrade: 'Connect your email',
    recover: 'Restore account access'
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

function storeChallenge(saved?: PendingChallenge) {
  try {
    if (saved) sessionStorage.setItem(challengeStorage, JSON.stringify(saved))
    else sessionStorage.removeItem(challengeStorage)
  } catch {
    // The current tab can finish verification without browser storage.
  }
}

async function invitationDigest(invitation: string) {
  if (!invitation) return ''
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(invitation))
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('')
}

function openChallenge(saved: PendingChallenge) {
  mode.value = saved.mode
  email.value = saved.email
  challenge.value = saved.id
  setupCode.value = ''
  legacyKey.value = ''
  resendDelay.value = Math.max(0, saved.requestedAt + resendInterval - Date.now())
  if (resendDelay.value) resend.start()
}

onMounted(async () => {
  const invitation = props.invitation
  try {
    const stored = sessionStorage.getItem(challengeStorage)
    const saved: PendingChallenge | null = JSON.parse(stored ?? 'null')
    if (saved && typeof saved.id === 'string' && /^[0-9a-f-]{36}$/i.test(saved.id)
      && typeof saved.email === 'string' && saved.email.length <= 254
      && (saved.mode === 'sign_in' || saved.mode === 'company' || saved.mode === 'upgrade' || saved.mode === 'recover')
      && typeof saved.requestedAt === 'number' && saved.requestedAt <= Date.now()
      && saved.requestedAt + codeLifetime > Date.now()
      && saved.invitationDigest === await invitationDigest(invitation)) {
      if (!pending.value && !challenge.value && invitation === props.invitation) {
        if (stored === sessionStorage.getItem(challengeStorage)) openChallenge(saved)
      }
    } else if (!pending.value && !challenge.value && invitation === props.invitation
      && stored === sessionStorage.getItem(challengeStorage)) {
      storeChallenge()
    }
  } catch {
    // Starting a fresh request remains available.
  }
})

function changeMode(next: Mode) {
  storeChallenge()
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

function changeEmail() {
  changeMode(mode.value)
  email.value = ''
}

watch(() => props.invitation, () => changeMode('sign_in'))

function backToSignIn() {
  changeMode('sign_in')
  if (props.recovery) void navigateTo({ path: '/workspace/', query: { view: 'security' } })
}

async function submit() {
  if (pending.value || sessionCheckError.value) return
  if (!challenge.value && purpose.value === 'company' && ['loading', 'unavailable'].includes(registration.value)) return
  const intent = purpose.value
  const invitation = props.invitation
  pending.value = true
  error.value = ''
  signInError.value = ''
  try {
    if (!challenge.value) {
      const additional = {
        sign_in: {},
        company: { company: company.value, name: name.value, setup_code: setupCode.value.trim() || undefined },
        invite: { token: invitation },
        upgrade: { key: legacyKey.value.trim(), token: invitation || undefined },
        recover: { key: legacyKey.value.trim() }
      }[intent]
      const saved = {
        id: crypto.randomUUID(), email: email.value.trim(), mode: mode.value,
        invitationDigest: await invitationDigest(invitation), requestedAt: Date.now()
      }
      if (invitation !== props.invitation) return
      storeChallenge(saved)
      try {
        await api('/api/account/email-codes', requestJson({
          id: saved.id, email: saved.email, purpose: intent, ...additional
        }))
      } catch (cause) {
        if (invitation !== props.invitation) return
        if (cause instanceof ApiError && cause.status < 500) {
          storeChallenge()
          throw cause
        }
        openChallenge(saved)
        error.value = 'The request was interrupted. Check your email for the code or request another one.'
        return
      }
      if (invitation !== props.invitation) return
      openChallenge(saved)
      await nextTick()
      codeInput.value?.inputRef?.focus()
      return
    }

    if (!verified.value) {
      await api('/api/account/email-codes/verify', requestJson({ id: challenge.value, code: code.value.trim() }))
      if (invitation === props.invitation) storeChallenge()
      verified.value = true
      code.value = ''
    }
    await refreshSession()
    if (intent === 'company') await navigateTo({ path: '/workspace/', query: { view: 'company' } }, { replace: true })
    if (intent === 'recover') await navigateTo({ path: '/workspace/', query: { view: 'security' } }, { replace: true })
    if (invitation === props.invitation) emit('done')
  } catch (cause) {
    if (props.invitation && cause instanceof ApiError && cause.status === 404) {
      error.value = 'This invitation is unavailable. Check the invited email address or ask for a new invitation.'
    } else if (purpose.value === 'upgrade' && !challenge.value && cause instanceof ApiError && cause.status === 401) {
      error.value = 'This key is unavailable. Check your access or recovery key.'
    } else if (purpose.value === 'recover' && !challenge.value && cause instanceof ApiError && cause.status === 401) {
      error.value = 'This recovery code is unavailable. Use your most recently saved code.'
    } else {
      error.value = cause instanceof ApiError ? cause.message : 'Could not reach DuctDelta. Try again.'
    }
  } finally {
    pending.value = false
  }
}
</script>

<template>
  <WorkspaceEntryShell :title="title">
    <template #default>
      <p v-if="purpose === 'sign_in' && !challenge" class="mt-3 text-muted">
        We’ll email you a sign-in code.
      </p>

      <UAlert
        v-if="route.query.sso_error"
        class="mt-4"
        color="error"
        variant="subtle"
        title="Company sign-in failed. Check with your company administrator."
      />
      <CompanySignInButton
        v-if="ssoCompany && purpose === 'sign_in' && !challenge"
        :company="ssoCompany"
        class="mt-4"
      />

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
      <form v-else class="mt-6 flex flex-col gap-4" @submit.prevent="submit">
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
          <p v-if="purpose === 'recover'" class="text-muted">
            Enter your saved recovery code and an email address you can access.
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
          <UFormField :label="purpose === 'recover' ? 'New email address' : 'Email address'" name="email" required>
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
            v-if="purpose === 'upgrade' || purpose === 'recover'"
            :label="purpose === 'recover' ? 'Saved recovery code' : 'Access or recovery key'"
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
          class="workspace-entry-primary"
          :label="challenge ? 'Continue' : 'Email me a code'"
          block
          :loading="pending"
          :disabled="!challenge && purpose === 'company' && ['loading', 'unavailable'].includes(registration)"
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

      <div class="workspace-entry-options flex flex-wrap gap-2 justify-between">
        <UButton
          v-if="challenge && !verified"
          label="Change email"
          color="neutral"
          variant="link"
          :disabled="pending"
          @click="changeEmail"
        />
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
          @click="changeMode('sign_in'); emit('cancel')"
        />
        <template v-else-if="purpose === 'sign_in' && !challenge">
          <div class="w-full">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <p class="text-sm text-muted">
                New to DuctDelta?
              </p>
              <UButton
                label="Create a company"
                variant="soft"
                :disabled="pending"
                @click="changeMode('company')"
              />
            </div>
            <div class="mt-3 flex flex-wrap gap-x-4">
              <UButton
                label="Use an existing key"
                color="neutral"
                variant="link"
                class="px-0 text-muted"
                :disabled="pending"
                @click="changeMode('upgrade')"
              />
              <UButton
                label="Recover account"
                color="neutral"
                variant="link"
                class="px-0 text-muted"
                :disabled="pending"
                @click="changeMode('recover')"
              />
              <UButton
                label="About DuctDelta"
                color="neutral"
                variant="link"
                class="px-0 text-muted"
                to="/"
                external
              />
            </div>
          </div>
        </template>
        <UButton
          v-else-if="!verified"
          label="Back to sign in"
          color="neutral"
          variant="link"
          :disabled="pending"
          @click="backToSignIn"
        />
      </div>
    </template>
  </WorkspaceEntryShell>
</template>
