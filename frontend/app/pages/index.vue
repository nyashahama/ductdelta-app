<script setup lang="ts">
import AccountSessions from '~/components/AccountSessions.vue'
import AccountSecurity from '~/components/AccountSecurity.vue'
import CompanySettings from '~/components/company/CompanySettings.vue'
import CasesWorkspace from '~/components/cases/CasesWorkspace.vue'
import ProjectNoticeRules from '~/components/cases/ProjectNoticeRules.vue'
import ObservationWorkspace from '~/components/observations/ObservationWorkspace.vue'
import CaptureObservation from '~/components/observations/CaptureObservation.vue'
import { api, reportError } from '~/utils/api'
import { formatDeadline, type Overview } from '~/types/overview'

const { session, project, projects, view, unavailableProject, error, expire, loadProjects, target } = useWorkspace()
const route = useRoute()
const period = ref<7 | 14 | 30>(14)
const periods = [7, 14, 30] as const
const data = shallowRef<Overview>()
const overviewError = ref('')
const loading = ref(false)
const version = ref(0)
const captureProject = ref<string>()
const source = ref<{ project: string, id: string }>()
const showNotices = ref(false)

const title = computed(() => ({
  'overview': 'Project overview',
  'observations': 'Observations',
  'cases': 'Change cases',
  'notice-rules': 'Notice rules',
  'company': 'Company settings',
  'sessions': 'Account sessions',
  'security': 'Account security'
})[view.value])
const selectedCase = computed(() => recordId(route.query.caseId))
const selectedObservation = computed(() => recordId(route.query.observationId))

function recordId(value: unknown) {
  return typeof value === 'string' && /^[a-f0-9-]{36}$/i.test(value) ? value : undefined
}

function changed() {
  version.value += 1
}

function beginCapture() {
  if (project.value?.permission === 'capture') captureProject.value = project.value.id
}

function openCase(id?: string) {
  source.value = undefined
  showNotices.value = false
  return navigateTo(target('cases', project.value?.id, id))
}

function openObservation(id: string) {
  return navigateTo(target('observations', project.value?.id, id))
}

function linkedCase(id: string) {
  if (!project.value) return
  source.value = { project: project.value.id, id }
  return navigateTo(target('cases', project.value.id))
}

function saveObservation(id: string) {
  captureProject.value = undefined
  changed()
  void openObservation(id)
}

watch(() => project.value?.id, () => {
  captureProject.value = undefined
  source.value = undefined
  showNotices.value = false
  data.value = undefined
})

watch(view, (page) => {
  if (page !== 'cases') source.value = undefined
})

watch([() => project.value?.id, view, period, version], ([id, page], _, onCleanup) => {
  overviewError.value = ''
  if (!id || page !== 'overview') return
  const controller = new AbortController()
  onCleanup(() => controller.abort())
  loading.value = true
  api<Overview>(`/api/projects/${id}/overview?days=${period.value}`, { signal: controller.signal })
    .then((result) => { if (!controller.signal.aborted) data.value = result })
    .catch((cause) => {
      if (!controller.signal.aborted) {
        data.value = undefined
        overviewError.value = reportError(cause, expire)
      }
    })
    .finally(() => { if (!controller.signal.aborted) loading.value = false })
}, { immediate: true })
</script>

<template>
  <UDashboardPanel id="home" :ui="{ body: 'gap-4 sm:gap-6' }">
    <template #header>
      <UDashboardNavbar :title="title" :ui="{ right: 'gap-3' }">
        <template #leading>
          <UDashboardSidebarCollapse />
        </template>

        <template #right>
          <USlideover
            v-if="project && view === 'overview'"
            v-model:open="showNotices"
            title="Notice deadlines"
            description="Unsent notices due soon or overdue"
          >
            <UButton
              aria-label="Notice deadlines"
              color="neutral"
              variant="ghost"
              square
            >
              <UChip :show="Boolean(data?.notices_due)" color="warning" inset>
                <UIcon name="i-lucide-bell" class="size-5 shrink-0" />
              </UChip>
            </UButton>

            <template #body>
              <p v-if="loading && !data" class="text-muted" role="status">
                Loading notices…
              </p>
              <UAlert
                v-else-if="overviewError"
                color="error"
                variant="subtle"
                :title="overviewError"
              />
              <p v-else-if="!data?.notices.length" class="text-muted">
                No notices due in the next 7 days.
              </p>
              <ul v-else class="divide-y divide-default">
                <li v-for="notice in data.notices" :key="`${notice.case_id}:${notice.reference}:${notice.due_at}`">
                  <UButton
                    color="neutral"
                    variant="ghost"
                    class="w-full justify-between my-1"
                    @click="openCase(notice.case_id)"
                  >
                    <span class="text-left whitespace-normal">
                      <span class="block text-highlighted font-medium">{{ notice.title }}</span>
                      <span class="block text-muted text-xs">{{ notice.reference }} · {{ formatDeadline(notice.due_at) }}</span>
                    </span>
                    <UIcon name="i-lucide-arrow-up-right" class="size-4 shrink-0" />
                  </UButton>
                </li>
              </ul>
            </template>
          </USlideover>
          <UTooltip v-if="project?.permission === 'capture' && view === 'overview'" text="New observation">
            <UButton
              icon="i-lucide-plus"
              aria-label="New observation"
              class="rounded-full"
              @click="beginCapture"
            />
          </UTooltip>
        </template>
      </UDashboardNavbar>

      <UDashboardToolbar v-if="project && view === 'overview'">
        <template #left>
          <span class="shrink-0 text-sm text-muted">Activity</span>
          <UFieldGroup role="group" aria-label="Activity range" :aria-busy="loading">
            <UButton
              v-for="days in periods"
              :key="days"
              :label="`${days} days`"
              color="neutral"
              :variant="period === days ? 'soft' : 'outline'"
              :aria-pressed="period === days"
              @click="period = days"
            />
          </UFieldGroup>
        </template>
      </UDashboardToolbar>
    </template>

    <template #body>
      <AccountSessions v-if="view === 'sessions'" />
      <AccountSecurity v-else-if="view === 'security'" />
      <CompanySettings v-else-if="view === 'company'" />
      <UAlert
        v-else-if="error"
        role="alert"
        color="error"
        variant="subtle"
        :title="error"
      >
        <template #actions>
          <UButton
            color="neutral"
            variant="outline"
            label="Retry loading projects"
            @click="loadProjects"
          />
        </template>
      </UAlert>
      <UAlert
        v-else-if="unavailableProject"
        role="alert"
        color="warning"
        variant="subtle"
        title="This project is unavailable. Select a project to continue."
      />
      <p v-else-if="!project" role="status" class="text-muted">
        {{ projects ? 'Your account has no assigned projects.' : 'Loading projects…' }}
      </p>
      <template v-else-if="view === 'overview'">
        <UAlert
          v-if="overviewError"
          role="alert"
          color="error"
          variant="subtle"
          :title="overviewError"
        >
          <template #actions>
            <UButton
              color="neutral"
              variant="outline"
              label="Retry loading overview"
              @click="changed"
            />
          </template>
        </UAlert>
        <p v-else-if="!data" class="text-muted" role="status">
          Loading project overview…
        </p>
        <template v-else>
          <HomeStats :data="data" />
          <HomeFollowUps
            :key="project.id"
            :project="project.id"
            :version="version"
            @open="openCase"
            @register="openCase()"
            @observation="openObservation"
            @session-expired="expire"
          />
          <HomeChart :activity="data.activity" />
          <HomeCases :cases="data.cases" @open="openCase" @register="openCase()" />
        </template>
      </template>
      <ObservationWorkspace
        v-else-if="view === 'observations'"
        :key="project.id"
        :project="project"
        :observation-id="selectedObservation"
        :version="version"
        @select="openObservation"
        @source-case="linkedCase"
        @capture="beginCapture"
        @session-expired="expire"
      />
      <ProjectNoticeRules
        v-else-if="view === 'notice-rules'"
        :key="project.id"
        :project="project.id"
        @session-expired="expire"
      />
      <CasesWorkspace
        v-else
        :key="project.id"
        :project="project"
        :selected-case-id="selectedCase ?? null"
        :source-observation-id="source?.project === project.id ? source.id : null"
        @select-case="openCase"
        @open-observation="openObservation"
        @changed="changed"
        @session-expired="expire"
      />

      <CaptureObservation
        v-if="session && project?.permission === 'capture' && captureProject === project.id"
        :key="project.id"
        :project="project"
        @close="captureProject = undefined"
        @saved="saveObservation"
        @session-expired="expire"
      />
    </template>
  </UDashboardPanel>
</template>
