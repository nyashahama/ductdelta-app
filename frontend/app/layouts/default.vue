<script setup lang="ts">
import type { NavigationMenuItem } from '@nuxt/ui'

const {
  session, project, projects, view, signInError, signing, target, restoreSession, signIn, signOut
} = useWorkspace()
const open = ref(false)
const key = ref('')

const links = computed<NavigationMenuItem[]>(() => ([
  { label: 'Overview', icon: 'i-lucide-house', to: target('overview'), active: view.value === 'overview' },
  { label: 'Observations', icon: 'i-lucide-clipboard-list', to: target('observations'), active: view.value === 'observations' },
  { label: 'Change cases', icon: 'i-lucide-folders', to: target('cases'), active: view.value === 'cases' }
].map(item => ({ ...item, onSelect: () => { open.value = false } }))))
const groups = computed(() => [{
  id: 'links',
  label: 'Go to',
  items: links.value.map(({ label, icon, to }) => ({ label, icon, to, onSelect: () => { open.value = false } }))
}])

async function submit() {
  await signIn(key.value)
  key.value = ''
}
async function selectProject(id: string) {
  open.value = false
  await navigateTo(target(view.value, id))
}

onMounted(restoreSession)
</script>

<template>
  <main v-if="session === undefined" class="min-h-dvh grid place-items-center" role="status">
    <p class="text-muted">
      Opening DuctDelta…
    </p>
  </main>

  <main v-else-if="!session" class="min-h-dvh grid place-items-center p-4">
    <UCard class="w-full max-w-md" aria-labelledby="sign-in-title">
      <template #header>
        <div class="flex items-center gap-2 text-highlighted font-semibold">
          <UIcon name="i-lucide-triangle" class="size-5 text-primary" />
          DuctDelta
        </div>
      </template>
      <h1 id="sign-in-title" class="text-2xl font-semibold text-highlighted">
        Sign in to your workspace
      </h1>
      <p class="mt-2 text-muted">
        Use your access key to open your projects.
      </p>
      <form class="mt-5 flex flex-col gap-3" @submit.prevent="submit">
        <UFormField label="Access key" name="key" required>
          <UInput
            v-model="key"
            name="key"
            type="password"
            autocomplete="current-password"
            required
            :readonly="signing"
            class="w-full"
          />
        </UFormField>
        <UAlert
          v-if="signInError"
          role="alert"
          color="error"
          variant="subtle"
          :title="signInError"
        />
        <UButton
          type="submit"
          :loading="signing"
          block
          label="Sign in"
        />
      </form>
    </UCard>
  </main>

  <UDashboardGroup v-else unit="rem">
    <UDashboardSidebar
      id="workspace"
      v-model:open="open"
      collapsible
      resizable
      class="bg-elevated/25"
      :ui="{ footer: 'lg:border-t lg:border-default' }"
    >
      <template #header="{ collapsed }">
        <TeamsMenu
          :collapsed="collapsed"
          :project="project"
          :projects="projects"
          @select="selectProject"
        />
      </template>

      <template #default="{ collapsed }">
        <UDashboardSearchButton :collapsed="collapsed" class="bg-transparent ring-default" />
        <UNavigationMenu
          :collapsed="collapsed"
          :items="links"
          orientation="vertical"
          tooltip
        />
      </template>

      <template #footer="{ collapsed }">
        <UserMenu
          :collapsed="collapsed"
          :name="session.name"
          :signing="signing"
          @sign-out="signOut"
        />
      </template>
    </UDashboardSidebar>

    <UDashboardSearch :groups="groups" />
    <slot />
  </UDashboardGroup>
</template>
