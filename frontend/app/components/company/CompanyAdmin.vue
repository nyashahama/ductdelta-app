<script setup lang="ts">
import { ApiError, api, reportError, requestJson } from '~/utils/api'
import MemberAccess from '~/components/company/MemberAccess.vue'
import type { CompanyProject, Member, Team } from '~/components/company/access'

const props = defineProps<{ companyId: string }>()
const { expire, loadCompanies, loadProjects, target } = useWorkspace()
const path = '/api/companies/' + props.companyId
const projects = ref<CompanyProject[]>([])
const team = ref<Team>()
const loading = ref(false)
const pending = ref(false)
const error = ref('')
const projectName = ref('')
const inviteName = ref('')
const inviteRole = ref<Member['role']>('member')
const inviteLink = ref<{ id: string, url: string }>()
const copied = ref('')
const editing = ref<Member>()
let projectDraft: { name: string, operation_id: string } | undefined
const roles = [
  { label: 'Team member', value: 'member' },
  { label: 'Company administrator', value: 'admin' }
]

async function refresh() {
  if (loading.value) return
  loading.value = true
  error.value = ''
  try {
    const [projectList, companyTeam] = await Promise.all([
      api<CompanyProject[]>(path + '/projects'),
      api<Team>(path + '/team')
    ])
    projects.value = projectList
    team.value = companyTeam
    if (inviteLink.value && !companyTeam.invitations.some(invite => invite.id === inviteLink.value?.id)) {
      inviteLink.value = undefined
    }
  } catch (cause) {
    if (cause instanceof ApiError && cause.status === 404) {
      projects.value = []
      team.value = undefined
      inviteLink.value = undefined
      editing.value = undefined
      await loadCompanies()
    }
    error.value = reportError(cause, expire)
  } finally {
    loading.value = false
  }
}

onMounted(refresh)

async function write(action: () => Promise<void>) {
  if (pending.value || loading.value) return
  pending.value = true
  error.value = ''
  try {
    await action()
    await refresh()
  } catch (cause) {
    error.value = reportError(cause, expire)
  } finally {
    pending.value = false
  }
}

function createProject() {
  return write(async () => {
    const name = projectName.value.trim()
    if (projectDraft?.name !== name) projectDraft = { name, operation_id: crypto.randomUUID() }
    await api<CompanyProject>(path + '/projects', requestJson(projectDraft))
    projectName.value = ''
    projectDraft = undefined
    await loadProjects()
  })
}

function invite() {
  return write(async () => {
    const result = await api<{ id: string, token: string }>(path + '/invitations', requestJson({
      name: inviteName.value.trim(),
      role: inviteRole.value
    }))
    inviteLink.value = { id: result.id, url: location.origin + '/#invite=' + result.token }
    inviteName.value = ''
    copied.value = ''
  })
}

async function copyLink() {
  if (!inviteLink.value) return
  try {
    await navigator.clipboard.writeText(inviteLink.value.url)
    copied.value = 'Invitation link copied.'
  } catch {
    copied.value = 'Select and copy the invitation link from the field.'
  }
}

function revoke(invitation: string) {
  return write(async () => {
    await api(path + '/invitations/' + invitation, { method: 'DELETE' })
  })
}

function expiry(value: string) {
  return new Intl.DateTimeFormat('en-ZA', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
}

async function memberChanged() {
  await Promise.all([refresh(), loadProjects(), loadCompanies()])
}
</script>

<template>
  <div class="space-y-4">
    <div class="flex justify-end">
      <UButton
        label="Refresh setup"
        icon="i-lucide-refresh-cw"
        color="neutral"
        variant="outline"
        :loading="loading"
        :disabled="pending"
        @click="refresh"
      />
    </div>
    <UAlert
      v-if="error"
      role="alert"
      color="error"
      variant="subtle"
      :title="error"
    />
    <div class="grid items-start gap-4 lg:grid-cols-2">
      <div class="min-w-0 space-y-4">
        <UCard>
          <template #header>
            <h2 class="font-semibold text-highlighted">
              Projects
            </h2>
          </template>
          <form class="flex flex-wrap items-end gap-2" @submit.prevent="createProject">
            <UFormField
              label="Project name"
              name="project-name"
              class="grow min-w-0"
              required
            >
              <UInput
                v-model="projectName"
                class="w-full"
                :maxlength="120"
                :readonly="pending"
                required
              />
            </UFormField>
            <UButton type="submit" label="Create project" :disabled="pending || loading || !projectName.trim()" />
          </form>
          <ul v-if="projects.length" class="mt-3 divide-y divide-default">
            <li v-for="project in projects" :key="project.id" class="py-2">
              <NuxtLink
                :to="target('overview', project.id)"
                class="inline-flex items-center gap-2 text-primary font-medium wrap-anywhere hover:underline"
              >
                <UIcon name="i-lucide-folder" class="size-4 shrink-0" />
                {{ project.name }}
              </NuxtLink>
            </li>
          </ul>
          <p v-else-if="!loading" class="mt-3 text-sm text-muted">
            No projects yet.
          </p>
        </UCard>

        <UCard>
          <template #header>
            <h2 class="font-semibold text-highlighted">
              Invitations
            </h2>
          </template>
          <form class="grid gap-3" @submit.prevent="invite">
            <UFormField label="Invitee name" name="invitee-name" required>
              <UInput
                v-model="inviteName"
                class="w-full"
                :maxlength="120"
                :readonly="pending"
                required
              />
            </UFormField>
            <UFormField label="Company role" name="invite-role">
              <USelect
                v-model="inviteRole"
                :items="roles"
                class="w-full"
                :disabled="pending"
              />
            </UFormField>
            <UButton type="submit" label="Create invitation" :disabled="pending || loading || !inviteName.trim()" />
          </form>
          <div v-if="inviteLink" class="mt-4 space-y-2">
            <UFormField label="Invitation link" name="invite-link">
              <UInput
                :model-value="inviteLink.url"
                class="w-full"
                readonly
                autocomplete="off"
              />
            </UFormField>
            <p class="text-sm text-muted">
              Send this single-use link privately. It expires in seven days.
            </p>
            <UButton
              label="Copy invitation link"
              color="neutral"
              variant="outline"
              @click="copyLink"
            />
            <p v-if="copied" role="status" class="text-sm text-muted">
              {{ copied }}
            </p>
          </div>
          <ul v-if="team?.invitations.length" class="mt-3 divide-y divide-default">
            <li v-for="invitation in team.invitations" :key="invitation.id" class="py-2 flex flex-wrap items-center justify-between gap-2">
              <div class="min-w-0 wrap-anywhere">
                <p class="font-medium text-highlighted">
                  {{ invitation.name }}
                </p>
                <p class="text-sm text-muted">
                  Expires {{ expiry(invitation.expires_at) }}
                </p>
              </div>
              <UButton
                label="Cancel invitation"
                color="neutral"
                variant="outline"
                size="sm"
                :disabled="pending || loading"
                @click="revoke(invitation.id)"
              />
            </li>
          </ul>
        </UCard>
      </div>

      <UCard class="min-w-0">
        <template #header>
          <h2 class="font-semibold text-highlighted">
            Team
          </h2>
        </template>
        <p v-if="loading && !team" role="status" class="text-muted">
          Loading team…
        </p>
        <ul v-else class="divide-y divide-default">
          <li v-for="member in team?.members" :key="member.id" class="py-3 first:pt-0 last:pb-0 flex flex-wrap items-center justify-between gap-2">
            <div class="min-w-0 wrap-anywhere">
              <p class="font-medium text-highlighted">
                {{ member.name }}{{ member.id === team?.actor_id ? ' (you)' : '' }}
              </p>
              <p class="text-sm text-muted">
                {{ member.role === 'admin' ? 'Company administrator' : 'Team member' }}
              </p>
            </div>
            <UButton
              label="Manage access"
              color="neutral"
              variant="outline"
              size="sm"
              @click="editing = member"
            />
          </li>
        </ul>
      </UCard>
    </div>
    <MemberAccess
      v-if="editing && team"
      :member="team.members.find(member => member.id === editing?.id) ?? editing"
      :path="path"
      :projects="projects"
      :access="team.access"
      @close="editing = undefined"
      @changed="memberChanged"
    />
  </div>
</template>
