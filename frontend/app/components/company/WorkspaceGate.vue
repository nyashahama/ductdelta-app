<script setup lang="ts">
import { ApiError, api, requestJson } from '~/utils/api'

const props = defineProps<{ invitation: string, pendingKeys: string[] }>()
const emit = defineEmits<{
  retain: [key: string]
  discard: [key: string]
  done: []
  joined: []
  cancel: []
}>()
const { session, signInError, sessionCheckError, signing, signIn, refreshSession, restoreSession, expire } = useWorkspace()

type Keys = { key: string, recovery_key: string }
const mode = ref<'sign-in' | 'company' | 'recover'>(props.pendingKeys.length ? 'recover' : 'sign-in')
const keys = ref<Keys>()
const key = ref(props.pendingKeys[0] ?? '')
const company = ref('')
const name = ref('')
const setupCode = ref('')
const registration = ref<'loading' | 'open' | 'code' | 'unavailable'>('loading')
const pending = ref(false)
const error = ref('')
const copied = ref('')
const openedCompany = ref(false)
const invitationSignIn = ref(false)
const joiningWithExistingAccount = computed(() => Boolean(props.invitation && invitationSignIn.value && !session.value))
const recovering = computed(() => !props.invitation && mode.value === 'recover')

const title = computed(() => {
  if (keys.value) return 'Save your sign-in keys'
  if (props.invitation) return 'Join the company'
  return {
    'sign-in': 'Sign in to your workspace',
    'company': 'Create your company',
    'recover': 'Recover your account'
  }[mode.value]
})

function changeMode(next: typeof mode.value) {
  mode.value = next
  key.value = next === 'recover' ? props.pendingKeys[0] ?? '' : ''
  setupCode.value = ''
  error.value = ''
}

function chooseInvitationSignIn(enabled: boolean) {
  invitationSignIn.value = enabled
  key.value = ''
  error.value = ''
  signInError.value = ''
}

function cancelInvitation() {
  chooseInvitationSignIn(false)
  emit('cancel')
}

async function loadRegistration() {
  registration.value = 'loading'
  try {
    const policy = await api<{ setup_code_required: boolean }>('/api/company-registration')
    registration.value = policy.setup_code_required ? 'code' : 'open'
  } catch {
    registration.value = 'unavailable'
  }
}

watch(mode, (next) => {
  if (next === 'company') void loadRegistration()
})

async function copy(value: string, label: string) {
  try {
    await navigator.clipboard.writeText(value)
    copied.value = label + ' copied.'
  } catch {
    copied.value = 'Select and copy the key from the field.'
  }
}

async function finish() {
  if (pending.value) return
  pending.value = true
  error.value = ''
  try {
    await refreshSession()
    if (openedCompany.value) await navigateTo({ path: '/', query: { view: 'company' } }, { replace: true })
    if (keys.value) emit('done')
    else emit('joined')
  } catch {
    error.value = 'Could not open your workspace. Try again.'
  } finally {
    pending.value = false
  }
}

async function submit() {
  if (pending.value || signing.value || (props.invitation && sessionCheckError.value)) return
  if (mode.value === 'company' && ['loading', 'unavailable'].includes(registration.value)) return
  const joining = joiningWithExistingAccount.value
  if (joining || (mode.value === 'sign-in' && !props.invitation)) {
    error.value = ''
    const signedIn = await signIn(key.value.trim())
    key.value = ''
    if (signedIn) {
      if (joining) chooseInvitationSignIn(false)
      else if (props.pendingKeys.length) changeMode('recover')
      else emit('done')
    }
    return
  }
  pending.value = true
  error.value = ''
  const currentAccount = Boolean(props.invitation && session.value)
  let recoveryKey = ''
  try {
    if (!currentAccount) {
      recoveryKey = [...crypto.getRandomValues(new Uint8Array(32))]
        .map(byte => byte.toString(16).padStart(2, '0')).join('')
      // Keep the recovery proof before sending a request whose response may be lost.
      emit('retain', recoveryKey)
      if (!sessionStorage.getItem('ductdelta-pending-keys')?.includes(recoveryKey)) {
        throw new Error('Browser storage is unavailable.')
      }
    }
    if (props.invitation) {
      const result = await api<{ id: string } & Partial<Keys>>('/api/invitations/accept', requestJson({
        token: props.invitation,
        use_current_account: currentAccount,
        recovery_key: recoveryKey || undefined
      }))
      if (result.key && result.recovery_key) keys.value = { key: result.key, recovery_key: result.recovery_key }
    } else if (mode.value === 'company') {
      keys.value = await api<Keys>('/api/companies', requestJson({
        company: company.value,
        name: name.value,
        recovery_key: recoveryKey,
        setup_code: setupCode.value.trim() || undefined
      }))
      setupCode.value = ''
      openedCompany.value = true
    } else {
      keys.value = await api<Keys>('/api/account/recover', requestJson({
        recovery_key: key.value.trim(),
        replacement_recovery_key: recoveryKey
      }))
    }
    if (currentAccount) {
      pending.value = false
      await finish()
    }
  } catch (cause) {
    if (cause instanceof ApiError && cause.status < 500 && recoveryKey) emit('discard', recoveryKey)
    if (props.invitation && cause instanceof ApiError && cause.status === 404) {
      error.value = 'This invitation has expired, was cancelled, or has already been used.'
    } else if (props.invitation && currentAccount && cause instanceof ApiError && cause.status === 401) {
      expire()
      chooseInvitationSignIn(true)
      error.value = 'Your session ended. Sign in again to accept this invitation.'
    } else if (mode.value === 'recover' && cause instanceof ApiError && cause.status === 401) {
      error.value = 'This recovery key is unavailable.'
    } else if (mode.value === 'company' && cause instanceof ApiError && cause.status === 403) {
      error.value = cause.message
    } else if (recoveryKey && props.pendingKeys.includes(recoveryKey)) {
      if (props.invitation) emit('cancel')
      changeMode('recover')
      key.value = recoveryKey
      error.value = 'The response was interrupted. Try recovery with the retained key before starting setup again.'
    } else {
      error.value = cause instanceof Error ? cause.message : 'Could not complete setup. Try again.'
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

      <template v-if="keys">
        <p class="mt-2 text-muted">
          Store your access key in a password manager. Keep your recovery key somewhere safe for use if you lose access.
        </p>
        <div class="my-5 grid gap-3">
          <UFormField label="Access key" name="new-access-key">
            <UInput
              :model-value="keys.key"
              readonly
              class="w-full font-mono"
              autocomplete="off"
            />
          </UFormField>
          <UButton
            label="Copy access key"
            variant="outline"
            color="neutral"
            @click="copy(keys.key, 'Access key')"
          />
          <UFormField label="Recovery key" name="new-recovery-key">
            <UInput
              :model-value="keys.recovery_key"
              readonly
              class="w-full font-mono"
              autocomplete="off"
            />
          </UFormField>
          <UButton
            label="Copy recovery key"
            variant="outline"
            color="neutral"
            @click="copy(keys.recovery_key, 'Recovery key')"
          />
          <p v-if="copied" role="status" class="text-sm text-muted">
            {{ copied }}
          </p>
        </div>
        <UButton
          label="I saved my keys"
          block
          :loading="pending"
          @click="finish"
        />
      </template>

      <form v-else class="mt-4 flex flex-col gap-3" @submit.prevent="submit">
        <UAlert
          v-if="invitation && sessionCheckError"
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
        <p v-else-if="invitation && !joiningWithExistingAccount" class="text-muted">
          {{ session ? 'Accept this invitation as ' + session.name + '.' : 'Accept this invitation to create a new DuctDelta account.' }}
        </p>
        <template v-else-if="!invitation && mode === 'company'">
          <UFormField label="Company name" name="company" required>
            <UInput
              v-model="company"
              required
              :maxlength="120"
              :readonly="pending"
              class="w-full"
              autocomplete="organization"
            />
          </UFormField>
          <UFormField label="Your name" name="name" required>
            <UInput
              v-model="name"
              required
              :maxlength="120"
              :readonly="pending"
              class="w-full"
              autocomplete="name"
            />
          </UFormField>
          <UFormField
            v-if="registration === 'code'"
            label="Company setup code"
            name="setup-code"
            required
          >
            <UInput
              v-model="setupCode"
              type="password"
              autocomplete="off"
              :maxlength="64"
              :readonly="pending"
              class="w-full"
              required
            />
          </UFormField>
          <UAlert
            v-if="registration === 'unavailable'"
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
        <template v-else>
          <p v-if="recovering && pendingKeys.length" class="text-sm text-muted">
            If setup was interrupted, try one of the saved recovery keys below.
          </p>
          <UFormField :label="recovering ? 'Recovery key' : 'Access key'" name="key" required>
            <UInput
              v-model="key"
              type="password"
              autocomplete="current-password"
              required
              :readonly="pending || signing"
              class="w-full"
            />
          </UFormField>
          <div v-if="recovering && pendingKeys.length" class="flex flex-wrap gap-2">
            <UButton
              v-for="(saved, index) in pendingKeys"
              :key="saved"
              :label="pendingKeys.length === 1 ? 'Use saved recovery key' : 'Use saved key ' + (index + 1)"
              color="neutral"
              variant="outline"
              size="sm"
              :disabled="pending"
              @click="key = saved"
            />
          </div>
        </template>
        <UButton
          type="submit"
          :label="invitation ? (joiningWithExistingAccount ? 'Sign in' : 'Accept invitation') : ({ 'sign-in': 'Sign in', 'company': 'Create company', 'recover': 'Recover account' })[mode]"
          block
          :loading="pending || signing"
          :disabled="Boolean(invitation && sessionCheckError) || (mode === 'company' && ['loading', 'unavailable'].includes(registration))"
        />
      </form>

      <UAlert
        v-if="error || (!keys && signInError && (joiningWithExistingAccount || (!invitation && mode === 'sign-in')))"
        class="mt-4"
        role="alert"
        color="error"
        variant="subtle"
        :title="error || signInError"
      />

      <template v-if="!keys && !pending">
        <div v-if="invitation" class="mt-4 flex flex-wrap gap-2 justify-between">
          <UButton
            v-if="!session && !sessionCheckError"
            :label="joiningWithExistingAccount ? 'Back to invitation' : 'Sign in to accept'"
            color="neutral"
            variant="link"
            :disabled="signing"
            @click="chooseInvitationSignIn(!joiningWithExistingAccount)"
          />
          <UButton
            label="Cancel invitation"
            color="neutral"
            variant="link"
            :disabled="signing"
            @click="cancelInvitation"
          />
        </div>
        <div v-else-if="mode === 'sign-in'" class="mt-4 flex flex-wrap gap-2 justify-between">
          <UButton
            label="Create a company"
            color="neutral"
            variant="link"
            @click="changeMode('company')"
          />
          <UButton
            label="Recover access"
            color="neutral"
            variant="link"
            @click="changeMode('recover')"
          />
          <UButton
            label="About DuctDelta"
            color="neutral"
            variant="link"
            to="/product/"
            external
          />
        </div>
        <UButton
          v-else
          class="mt-4"
          label="Back to sign in"
          color="neutral"
          variant="link"
          @click="changeMode('sign-in')"
        />
        <UButton
          v-if="!invitation && session && pendingKeys.length"
          class="mt-4"
          label="Continue without restoring this setup"
          color="neutral"
          variant="link"
          @click="emit('done')"
        />
      </template>
    </UCard>
  </main>
</template>
