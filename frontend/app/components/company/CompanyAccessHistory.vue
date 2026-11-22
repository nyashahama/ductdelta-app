<script setup lang="ts">
import { api, reportError, requestJson } from '~/utils/api'
import type { Capability, Member } from '~/components/company/access'

const props = defineProps<{ companyId: string, revision?: number }>()
const { expire } = useWorkspace()

type Lifetime = { days: number }
type AccessState = {
  days?: number
  role?: Member['role']
  permission?: 'read' | 'capture'
  capabilities?: Capability[]
  expires_at?: string
  reason?: 'inviter_lost_admin'
}
type AccessEvent = {
  id: string
  kind: 'invitation_created' | 'invitation_revoked' | 'invitation_accepted' | 'invitation_lifetime_changed'
    | 'company_role_changed' | 'company_member_removed' | 'project_access_changed'
  actor_name: string | null
  target_name: string | null
  project_name: string | null
  recorded_at: string
  before: AccessState | null
  after: AccessState | null
}
type History = { events: AccessEvent[], next_before: string | null }

const savedDays = ref<number>()
const days = ref<number | string>('')
const events = ref<AccessEvent[]>([])
const nextBefore = ref<string | null>(null)
const loading = ref(true)
const loadingOlder = ref(false)
const saving = ref(false)
const error = ref('')
const status = ref('')
let requestId = 0
const apiPath = computed(() => '/api/companies/' + props.companyId)
const validDays = computed(() => {
  const value = Number(days.value)
  return Number.isInteger(value) && value >= 1 && value <= 14
})

async function refresh() {
  const currentRequest = ++requestId
  loading.value = true
  error.value = ''
  try {
    const [lifetime, activity] = await Promise.all([
      api<Lifetime>(apiPath.value + '/invitation-lifetime'),
      api<History>(apiPath.value + '/access-history')
    ])
    if (currentRequest !== requestId) return
    if (savedDays.value === undefined || Number(days.value) === savedDays.value) {
      days.value = lifetime.days
    }
    savedDays.value = lifetime.days
    events.value = activity.events
    nextBefore.value = activity.next_before
  } catch (cause) {
    if (currentRequest !== requestId) return
    savedDays.value = undefined
    events.value = []
    nextBefore.value = null
    error.value = reportError(cause, expire)
  } finally {
    if (currentRequest === requestId) loading.value = false
  }
}

async function save() {
  if (!validDays.value || saving.value || Number(days.value) === savedDays.value) return
  saving.value = true
  status.value = ''
  error.value = ''
  try {
    const lifetime = await api<Lifetime>(apiPath.value + '/invitation-lifetime', {
      ...requestJson({ days: Number(days.value) }),
      method: 'PUT'
    })
    savedDays.value = lifetime.days
    days.value = lifetime.days
    status.value = 'Invitation lifetime saved.'
    await refresh()
  } catch (cause) {
    error.value = reportError(cause, expire)
  } finally {
    saving.value = false
  }
}

async function loadOlder() {
  if (loading.value || loadingOlder.value || !nextBefore.value) return
  const currentRequest = requestId
  loadingOlder.value = true
  error.value = ''
  try {
    const older = await api<History>(apiPath.value + '/access-history?before=' + nextBefore.value)
    if (currentRequest !== requestId) return
    events.value.push(...older.events)
    nextBefore.value = older.next_before
  } catch (cause) {
    if (currentRequest === requestId) error.value = reportError(cause, expire)
  } finally {
    loadingOlder.value = false
  }
}

const dateTime = new Intl.DateTimeFormat('en-ZA', { dateStyle: 'medium', timeStyle: 'short' })
const roleLabel = (role?: Member['role']) => role === 'admin' ? 'Company administrator' : 'Team member'
const capabilityLabels: Record<Capability, string> = {
  direction: 'Direction',
  commercial: 'Commercial',
  finance: 'Finance'
}
const titles = {
  invitation_created: 'Invitation created',
  invitation_revoked: 'Invitation revoked',
  invitation_accepted: 'Invitation accepted',
  invitation_lifetime_changed: 'Default invitation lifetime changed',
  company_role_changed: 'Company role changed',
  company_member_removed: 'Company member removed',
  project_access_changed: 'Project access changed'
}

function projectAccess(value: AccessState | null) {
  if (!value?.permission) return 'No project access'
  const permission = value.permission === 'capture' ? 'Capture' : 'Read'
  return [permission, ...(value.capabilities ?? []).map(capability => capabilityLabels[capability])].join(', ')
}

function details(event: AccessEvent) {
  const target = event.target_name
  switch (event.kind) {
    case 'invitation_created':
      return [target, roleLabel(event.after?.role), event.after?.expires_at
        ? 'Expires ' + dateTime.format(new Date(event.after.expires_at))
        : null].filter(Boolean).join(' · ')
    case 'invitation_revoked':
      return [target, event.after?.reason ? 'The inviter lost administrator access' : null].filter(Boolean).join(' · ')
    case 'invitation_accepted':
      return [target, roleLabel(event.after?.role)].filter(Boolean).join(' · ')
    case 'invitation_lifetime_changed':
      return `${event.before?.days} days → ${event.after?.days} days`
    case 'company_role_changed':
      return `${target ?? 'Company member'} · ${roleLabel(event.before?.role)} → ${roleLabel(event.after?.role)}`
    case 'company_member_removed':
      return [target, roleLabel(event.before?.role)].filter(Boolean).join(' · ')
    case 'project_access_changed':
      return `${target ?? 'Company member'} · ${event.project_name ?? 'Project'} · ${projectAccess(event.before)} → ${projectAccess(event.after)}`
  }
}

onMounted(refresh)
watch(() => props.revision, refresh)
</script>

<template>
  <UCard>
    <template #header>
      <h2 class="font-semibold text-highlighted">
        Invitation lifetime and access history
      </h2>
    </template>

    <div class="space-y-5">
      <UAlert
        v-if="error"
        role="alert"
        color="error"
        variant="subtle"
        :title="error"
      />
      <form
        v-if="savedDays !== undefined"
        class="flex flex-wrap items-end gap-3"
        @submit.prevent="save"
      >
        <UFormField
          label="Default invitation lifetime"
          name="invitation-lifetime"
          description="Choose 1 to 14 days. This applies to new invitations."
        >
          <UInput
            v-model.number="days"
            type="number"
            min="1"
            max="14"
            step="1"
            class="w-full"
          />
        </UFormField>
        <UButton
          type="submit"
          label="Save lifetime"
          :loading="saving"
          :disabled="loading || !validDays || Number(days) === savedDays"
        />
      </form>
      <p v-if="status" role="status" class="text-sm text-muted">
        {{ status }}
      </p>

      <section aria-labelledby="company-access-activity" class="space-y-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 id="company-access-activity" class="font-medium text-highlighted">
            Recent access changes
          </h3>
          <UButton
            label="Refresh history"
            size="sm"
            color="neutral"
            variant="outline"
            :loading="loading"
            @click="refresh"
          />
        </div>
        <ol v-if="events.length" class="divide-y divide-default border-y border-default">
          <li v-for="event in events" :key="event.id" class="space-y-1 py-3 text-sm">
            <div class="flex flex-wrap justify-between gap-x-3 gap-y-1">
              <strong class="font-medium text-highlighted">{{ titles[event.kind] }}</strong>
              <time :datetime="event.recorded_at" class="text-muted">{{ dateTime.format(new Date(event.recorded_at)) }}</time>
            </div>
            <p class="text-muted">
              {{ event.actor_name ?? 'Company account' }}
            </p>
            <p v-if="details(event)" class="wrap-anywhere">
              {{ details(event) }}
            </p>
          </li>
        </ol>
        <p v-else-if="!loading && !error" class="text-sm text-muted">
          No access changes recorded yet.
        </p>
        <UButton
          v-if="nextBefore"
          label="Show older changes"
          color="neutral"
          variant="outline"
          :loading="loadingOlder"
          :disabled="loading"
          @click="loadOlder"
        />
      </section>
    </div>
  </UCard>
</template>
