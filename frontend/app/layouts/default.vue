<script setup lang="ts">
import type { NavigationMenuItem } from '@nuxt/ui'
import EmailWorkspaceGate from '~/components/company/EmailWorkspaceGate.vue'
import WorkspaceGate from '~/components/company/WorkspaceGate.vue'
import { api } from '~/utils/api'

const {
  session, companies, project, projects, view, signing, target, restoreSession, signOut
} = useWorkspace()
const open = ref(false)
const route = useRoute()
const router = useRouter()
const invitation = ref('')
const invitationStorage = 'ductdelta-pending-invitation'
const pendingKeys = ref<string[]>([])
const keyStorage = 'ductdelta-pending-keys'
const emailSignIn = ref<boolean>()
const policyError = ref(false)
const recovery = computed(() => emailSignIn.value === true && route.query.recover === '1' && !invitation.value)
const ssoSignIn = computed(() => emailSignIn.value === true && typeof route.query.sso === 'string'
  && /^[a-f0-9-]{36}$/i.test(route.query.sso) && !invitation.value)
const needsGate = computed(() => !session.value || Boolean(invitation.value) || recovery.value || ssoSignIn.value
  || (emailSignIn.value !== true && pendingKeys.value.length > 0))

async function loadSignInPolicy() {
  policyError.value = false
  try {
    emailSignIn.value = (await api<{ enabled: boolean }>('/api/account/email-sign-in')).enabled
  } catch {
    policyError.value = true
  }
}

function storeKeys(keys: string[]) {
  try {
    if (keys.length) sessionStorage.setItem(keyStorage, JSON.stringify(keys))
    else sessionStorage.removeItem(keyStorage)
    pendingKeys.value = keys
  } catch {
    // The enrollment screen checks that a recovery key was retained before submitting.
  }
}

function addKey(key: string) {
  storeKeys([key, ...pendingKeys.value])
}

function discardKey(key: string) {
  storeKeys(pendingKeys.value.filter(saved => saved !== key))
}

function clearInvitation() {
  invitation.value = ''
  try {
    sessionStorage.removeItem(invitationStorage)
  } catch {
    // The current tab can still continue.
  }
  // Browsers that block session storage retain the invite in the fragment until it is cleared.
  if (new URLSearchParams(location.hash.slice(1)).has('invite')) {
    void router.replace({ path: route.path, query: route.query, hash: '' })
  }
}

function entered() {
  clearInvitation()
  storeKeys([])
  if (recovery.value || ssoSignIn.value || route.query.sso_error) {
    void router.replace(target('security'))
  }
}

const links = computed<NavigationMenuItem[]>(() => ([
  { label: 'Overview', icon: 'i-lucide-house', to: target('overview'), active: view.value === 'overview' },
  { label: 'Observations', icon: 'i-lucide-clipboard-list', to: target('observations'), active: view.value === 'observations' },
  { label: 'Change cases', icon: 'i-lucide-folders', to: target('cases'), active: view.value === 'cases' },
  ...(project.value
    ? [{ label: 'Notice rules', icon: 'i-lucide-scroll-text', to: target('notice-rules'), active: view.value === 'notice-rules' }]
    : []),
  ...(companies.value.some(company => company.role === 'admin')
    ? [{ label: 'Company settings', icon: 'i-lucide-building-2', to: target('company'), active: view.value === 'company' }]
    : [])
].map(item => ({ ...item, onSelect: () => { open.value = false } }))))
const groups = computed(() => [{
  id: 'links',
  label: 'Go to',
  items: links.value.map(({ label, icon, to }) => ({ label, icon, to, onSelect: () => { open.value = false } }))
}])

async function selectProject(id: string) {
  open.value = false
  await navigateTo(target(['company', 'sessions', 'security'].includes(view.value) ? 'overview' : view.value, id))
}

function readInvitation(hash: string) {
  const token = new URLSearchParams(hash.slice(1)).get('invite')
  if (!token || !/^[a-f0-9]{64}$/i.test(token)) return
  invitation.value = token
  try {
    sessionStorage.setItem(invitationStorage, token)
    void router.replace({ path: route.path, query: route.query, hash: '' })
  } catch {
    // Leave the fragment available for reload when the browser blocks session storage.
  }
}

// Nuxt applies the initial fragment after restoring the prerendered route.
watch(() => route.hash, hash => readInvitation(hash), { flush: 'post' })

onMounted(async () => {
  try {
    const saved: unknown = JSON.parse(sessionStorage.getItem(keyStorage) ?? '[]')
    if (Array.isArray(saved)) pendingKeys.value = saved.filter((key): key is string => typeof key === 'string' && /^[a-f0-9]{64}$/.test(key))
    const savedInvite = sessionStorage.getItem(invitationStorage)
    if (savedInvite && /^[a-f0-9]{64}$/i.test(savedInvite)) invitation.value = savedInvite
  } catch {
    pendingKeys.value = []
  }
  readInvitation(location.hash)
  await Promise.all([restoreSession(), loadSignInPolicy()])
})
</script>

<template>
  <main
    v-if="session === undefined || (needsGate && emailSignIn === undefined)"
    class="min-h-dvh grid place-items-center"
  >
    <UAlert
      v-if="policyError"
      color="error"
      variant="subtle"
      title="Could not load sign-in."
    >
      <template #actions>
        <UButton
          label="Try again"
          color="neutral"
          variant="outline"
          @click="loadSignInPolicy"
        />
      </template>
    </UAlert>
    <p v-else class="text-muted" role="status">
      Opening DuctDelta…
    </p>
  </main>

  <EmailWorkspaceGate
    v-else-if="needsGate && emailSignIn"
    :invitation="invitation"
    :saved-key="pendingKeys[0]"
    :recovery="recovery"
    @done="entered"
    @cancel="clearInvitation"
  />

  <WorkspaceGate
    v-else-if="needsGate"
    :invitation="invitation"
    :pending-keys="pendingKeys"
    @retain="addKey"
    @discard="discardKey"
    @done="entered"
    @joined="clearInvitation"
    @cancel="clearInvitation"
  />

  <UDashboardGroup v-else-if="session" unit="rem">
    <UDashboardSidebar
      id="workspace"
      v-model:open="open"
      collapsible
      resizable
      class="workspace-sidebar"
      :ui="{
        header: 'workspace-sidebar-heading px-4',
        body: 'workspace-sidebar-menu px-3',
        content: 'workspace-sidebar',
        footer: 'lg:border-t lg:border-default'
      }"
    >
      <template #header="{ collapsed }">
        <WorkspaceBrand :compact="collapsed" :class="{ 'justify-center': collapsed }" />
      </template>

      <template #default="{ collapsed }">
        <TeamsMenu
          :collapsed="collapsed"
          :project="project"
          :projects="projects"
          @select="selectProject"
        />
        <UDashboardSearchButton :collapsed="collapsed" class="bg-transparent ring-default" />
        <UNavigationMenu
          :collapsed="collapsed"
          :items="links"
          orientation="vertical"
          tooltip
          :ui="{ link: 'min-h-10 rounded-lg' }"
        />
      </template>

      <template #footer="{ collapsed }">
        <UserMenu
          :collapsed="collapsed"
          :name="session.name"
          :signing="signing"
          @open-sessions="open = false"
          @sign-out="signOut"
        />
      </template>
    </UDashboardSidebar>

    <UDashboardSearch :groups="groups" />
    <slot />
  </UDashboardGroup>
</template>
