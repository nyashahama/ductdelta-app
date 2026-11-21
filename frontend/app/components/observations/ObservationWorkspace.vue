<script setup lang="ts">
import { api, reportError, type Project } from '~/utils/api'

type ObservationSummary = {
  id: string
  note_preview: string
  location: string | null
  recorded_at: string
}

type Observation = Omit<ObservationSummary, 'note_preview'> & {
  note: string
  actor_id: string
  observed_at: string | null
}

type ObservationPage = {
  observations: ObservationSummary[]
  next: string | null
}

const props = defineProps<{ project: Project, observationId?: string, version: number }>()
const emit = defineEmits<{
  'select': [id: string]
  'source-case': [id: string]
  'capture': []
  'session-expired': []
}>()

const path = computed(() => `/api/projects/${props.project.id}/observations`)
const captureAllowed = computed(() => props.project.permission === 'capture')
const rows = ref<ObservationSummary[]>()
const next = ref<string | null>(null)
const listError = ref('')
const retry = ref(0)
const detail = ref<Observation>()
const detailError = ref('')
const detailRetry = ref(0)
const olderRequest = shallowRef<AbortController>()

const date = new Intl.DateTimeFormat('en-ZA', {
  dateStyle: 'medium',
  timeStyle: 'medium',
  timeZone: 'UTC'
})

function displayTimestamp(value: string) {
  return date.format(new Date(value)) + ' UTC'
}

function sessionExpired() {
  emit('session-expired')
}

watch([path, () => props.version, retry], async ([url], _previous, onCleanup) => {
  rows.value = undefined
  next.value = null
  listError.value = ''
  if (!import.meta.client) return

  const controller = new AbortController()
  onCleanup(() => {
    controller.abort()
    olderRequest.value?.abort()
    olderRequest.value = undefined
  })

  try {
    const page = await api<ObservationPage>(url, { signal: controller.signal })
    if (controller.signal.aborted) return
    rows.value = page.observations
    next.value = page.next
  } catch (error) {
    if (!controller.signal.aborted) listError.value = reportError(error, sessionExpired)
  }
}, { immediate: true })

watch([path, () => props.observationId, detailRetry], async ([url, id], _previous, onCleanup) => {
  detail.value = undefined
  detailError.value = ''
  if (!import.meta.client || !id) return

  const controller = new AbortController()
  onCleanup(() => controller.abort())

  try {
    const record = await api<Observation>(`${url}/${id}`, { signal: controller.signal })
    if (!controller.signal.aborted) detail.value = record
  } catch (error) {
    if (!controller.signal.aborted) detailError.value = reportError(error, sessionExpired)
  }
}, { immediate: true })

async function loadOlder() {
  if (!next.value || olderRequest.value) return

  const controller = new AbortController()
  olderRequest.value = controller
  listError.value = ''

  try {
    const page = await api<ObservationPage>(`${path.value}?before=${encodeURIComponent(next.value)}`, {
      signal: controller.signal
    })
    if (controller.signal.aborted) return
    rows.value = [...(rows.value ?? []), ...page.observations]
    next.value = page.next
  } catch (error) {
    if (!controller.signal.aborted) listError.value = reportError(error, sessionExpired)
  } finally {
    if (olderRequest.value === controller) olderRequest.value = undefined
  }
}
</script>

<template>
  <div class="min-w-0 space-y-4">
    <div v-if="captureAllowed" class="flex justify-end">
      <UButton
        type="button"
        icon="i-lucide-file-plus-2"
        label="New observation"
        @click="emit('capture')"
      />
    </div>

    <div class="grid min-w-0 gap-4 lg:grid-cols-2">
      <UCard as="section" class="min-w-0" aria-label="Observation log">
        <template #header>
          <h2 class="font-semibold text-highlighted">
            Observation log
          </h2>
        </template>

        <p v-if="!rows && !listError" role="status" class="text-sm text-muted">
          Loading observations…
        </p>
        <p v-if="rows?.length === 0" class="text-sm text-muted">
          No observations have been recorded.
        </p>
        <ul v-if="rows?.length" class="divide-y divide-default">
          <li v-for="row in rows" :key="row.id" class="py-1">
            <UButton
              type="button"
              color="neutral"
              :variant="observationId === row.id ? 'soft' : 'ghost'"
              :aria-pressed="observationId === row.id"
              class="w-full text-left"
              @click="emit('select', row.id)"
            >
              <span class="grid min-w-0 gap-1">
                <span class="wrap-anywhere">{{ row.note_preview || 'Open observation' }}</span>
                <span class="text-xs text-muted wrap-anywhere">
                  <template v-if="row.location">{{ row.location }} · </template>
                  <time :datetime="row.recorded_at">{{ displayTimestamp(row.recorded_at) }}</time>
                </span>
              </span>
            </UButton>
          </li>
        </ul>
        <p v-if="listError" role="alert" class="mt-3 text-sm text-error">
          {{ listError }}
        </p>

        <template v-if="next || (!rows && listError)" #footer>
          <UButton
            v-if="next"
            type="button"
            color="neutral"
            variant="outline"
            label="Load earlier observations"
            :loading="Boolean(olderRequest)"
            @click="loadOlder"
          />
          <UButton
            v-else
            type="button"
            color="neutral"
            variant="outline"
            label="Retry loading observations"
            @click="retry++"
          />
        </template>
      </UCard>

      <UCard as="section" class="min-w-0" aria-label="Observation record">
        <template #header>
          <h2 class="font-semibold text-highlighted">
            Observation record
          </h2>
        </template>

        <p v-if="!observationId" class="text-sm text-muted">
          Select an observation to read its full record.
        </p>
        <div v-else-if="detailError" class="space-y-3">
          <p role="alert" class="text-sm text-error">
            {{ detailError }}
          </p>
          <UButton
            type="button"
            color="neutral"
            variant="outline"
            label="Retry loading record"
            @click="detailRetry++"
          />
        </div>
        <p v-else-if="!detail" role="status" class="text-sm text-muted">
          Loading observation…
        </p>
        <div v-else class="space-y-4">
          <p class="whitespace-pre-wrap wrap-anywhere">
            {{ detail.note }}
          </p>
          <dl class="grid gap-3 text-sm wrap-anywhere sm:grid-cols-2">
            <div>
              <dt class="text-muted">
                Location
              </dt>
              <dd>{{ detail.location || 'Not recorded' }}</dd>
            </div>
            <div>
              <dt class="text-muted">
                Observed
              </dt>
              <dd>
                <time v-if="detail.observed_at" :datetime="detail.observed_at">{{ displayTimestamp(detail.observed_at) }}</time>
                <span v-else>Not recorded</span>
              </dd>
            </div>
            <div>
              <dt class="text-muted">
                Recorded
              </dt>
              <dd><time :datetime="detail.recorded_at">{{ displayTimestamp(detail.recorded_at) }}</time></dd>
            </div>
            <div>
              <dt class="text-muted">
                Recorded by
              </dt>
              <dd>{{ detail.actor_id }}</dd>
            </div>
            <div>
              <dt class="text-muted">
                Record ID
              </dt>
              <dd>{{ detail.id }}</dd>
            </div>
          </dl>
          <UButton
            v-if="captureAllowed"
            type="button"
            color="neutral"
            variant="outline"
            label="Create linked case"
            @click="emit('source-case', detail.id)"
          />
        </div>
      </UCard>
    </div>
  </div>
</template>
