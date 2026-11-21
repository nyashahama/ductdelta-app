<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import type { Project } from '../../utils/api'
import CaseActions from './CaseActions.vue'
import CaseFiles from './CaseFiles.vue'
import CaseFinance from './CaseFinance.vue'
import CaseTimeline from './CaseTimeline.vue'
import CreateCaseModal from './CreateCaseModal.vue'
import { casePath, type CasePage, type CaseRecord, type CaseSummary } from './case-data'
import { useCaseResource } from './useCaseResource'

const props = defineProps<{ project: Project, selectedCaseId: string | null, sourceObservationId: string | null }>()
const emit = defineEmits<{
  'select-case': [id: string]
  'open-observation': [id: string]
  'changed': []
  'session-expired': []
}>()

const cursor = ref<string | null>(null)
const previous = ref<CaseSummary[]>([])
const statuses = ref<Record<string, boolean>>({})
const newCase = ref(false)
const dismissedSource = ref<string | null>(null)
const confirmation = ref('')
const heading = ref<HTMLHeadingElement>()
const expire = () => emit('session-expired')
const registerPath = computed(() => casePath(props.project.id) + (cursor.value ? '?before=' + encodeURIComponent(cursor.value) : ''))
const selectedPath = computed(() => props.selectedCaseId ? casePath(props.project.id, props.selectedCaseId) : null)
const { resource: page, reload: reloadList } = useCaseResource<CasePage>(registerPath, expire)
const { resource: detail, reload: reloadDetail } = useCaseResource<CaseRecord>(selectedPath, expire)
const linkedSource = computed(() => props.sourceObservationId !== dismissedSource.value ? props.sourceObservationId : null)
const canCreate = computed(() => props.project.permission === 'capture')
const record = computed(() => detail.value.kind === 'ready' ? detail.value.data : null)
const rows = computed(() => [...previous.value, ...(page.value.kind === 'ready' ? page.value.data.cases : [])]
  .map(item => ({ ...item, closed: statuses.value[item.id] ?? item.closed })))
const next = computed(() => page.value.kind === 'ready' ? page.value.data.next_before : null)

watch(() => props.project.id, () => {
  cursor.value = null
  previous.value = []
  statuses.value = {}
  confirmation.value = ''
  newCase.value = false
  dismissedSource.value = null
  focusedCase = null
})
watch(() => props.sourceObservationId, (id) => {
  if (id === null) dismissedSource.value = null
})
watch(() => props.selectedCaseId, () => {
  confirmation.value = ''
})

let focusedCase: string | null = null
watch(record, async (current) => {
  if (!current) return
  statuses.value[current.id] = current.closed
  if (focusedCase === current.id) return
  focusedCase = current.id
  await nextTick()
  heading.value?.focus()
})

function loadEarlier() {
  if (!next.value) return
  previous.value = rows.value
  cursor.value = next.value
}

function dismissCreate() {
  newCase.value = false
  if (linkedSource.value) dismissedSource.value = linkedSource.value
}

function savedCase(id: string) {
  dismissCreate()
  previous.value = []
  cursor.value = null
  reloadList()
  emit('select-case', id)
  emit('changed')
}

function openObservation() {
  const id = record.value?.observation_id
  if (id) emit('open-observation', id)
}

function savedAction() {
  confirmation.value = 'Action recorded.'
  reloadDetail()
  emit('changed')
}
</script>

<template>
  <section class="min-w-0 space-y-4" aria-label="Change cases">
    <header v-if="canCreate" class="flex justify-end">
      <UButton icon="i-lucide-plus" @click="newCase = true">
        New case
      </UButton>
    </header>

    <div class="grid min-w-0 items-start gap-4 lg:grid-cols-[minmax(12rem,1fr)_minmax(0,3fr)]">
      <UCard
        as="section"
        class="min-w-0"
        aria-label="Case register"
        :ui="{ header: 'px-4 py-3 sm:px-4', body: 'p-0 sm:p-0' }"
      >
        <template #header>
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="font-semibold text-highlighted">
              Case register
            </h2>
            <UBadge v-if="rows.length" color="neutral" variant="subtle">
              {{ rows.length }} {{ next ? 'loaded' : rows.length === 1 ? 'case' : 'cases' }}
            </UBadge>
          </div>
        </template>

        <ul v-if="rows.length" class="max-h-[32vh] divide-y divide-default overflow-y-auto lg:max-h-[66vh]">
          <li v-for="item in rows" :key="item.id">
            <button
              type="button"
              class="flex w-full items-start justify-between gap-2 border-s-2 px-3 py-3 text-left text-sm hover:bg-elevated focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-primary"
              :class="item.id === selectedCaseId ? 'border-primary bg-elevated' : 'border-transparent'"
              :aria-label="item.title"
              :aria-pressed="item.id === selectedCaseId"
              @click="emit('select-case', item.id)"
            >
              <span class="min-w-0 font-medium wrap-anywhere text-highlighted">{{ item.title }}</span>
              <UBadge :color="item.closed ? 'neutral' : 'primary'" variant="subtle">
                {{ item.closed ? 'Closed' : 'Open' }}
              </UBadge>
            </button>
          </li>
        </ul>
        <p v-if="page.kind === 'loading'" class="p-4 text-sm text-muted" role="status">
          Loading change cases…
        </p>
        <div v-else-if="page.kind === 'error'" class="space-y-3 p-4">
          <p role="alert" class="text-sm text-error">
            {{ page.message }}
          </p>
          <UButton color="neutral" variant="outline" @click="reloadList">
            Reload case register
          </UButton>
        </div>
        <p v-else-if="!rows.length" class="p-4 text-sm text-muted">
          No change cases have been recorded for this project.
        </p>
        <div v-if="next" class="border-t border-default p-3">
          <UButton color="neutral" variant="outline" @click="loadEarlier">
            Load earlier cases
          </UButton>
        </div>
      </UCard>

      <div class="min-w-0 space-y-4">
        <UCard v-if="!selectedCaseId" :ui="{ body: 'p-4 sm:p-4' }">
          <p class="text-sm text-muted">
            Select a case to open its record.
          </p>
        </UCard>
        <UCard v-else-if="detail.kind === 'loading'" :ui="{ body: 'p-4 sm:p-4' }">
          <p class="text-sm text-muted" role="status">
            Loading case record…
          </p>
        </UCard>
        <UCard v-else-if="detail.kind === 'error'" :ui="{ body: 'space-y-3 p-4 sm:p-4' }">
          <p class="text-sm text-error" role="alert">
            {{ detail.message }}
          </p>
          <UButton color="neutral" variant="outline" @click="reloadDetail">
            Reload case record
          </UButton>
        </UCard>
        <template v-else-if="record && selectedPath">
          <UCard as="section" aria-label="Case summary" :ui="{ body: 'space-y-3 p-4 sm:p-4' }">
            <div class="flex flex-wrap items-center gap-2">
              <h2 ref="heading" tabindex="-1" class="text-xl font-semibold wrap-anywhere text-highlighted">
                {{ record.title }}
              </h2>
              <UBadge :color="record.closed ? 'neutral' : 'primary'" variant="subtle">
                {{ record.closed ? 'Closed' : 'Open' }}
              </UBadge>
            </div>
            <dl class="flex flex-wrap gap-x-5 gap-y-2 text-sm">
              <div>
                <dt class="text-xs text-muted">
                  Agreement
                </dt>
                <dd class="font-medium wrap-anywhere">
                  {{ record.agreement ?? 'Not recorded' }}
                </dd>
              </div>
              <div class="min-w-0">
                <dt class="text-xs text-muted">
                  Case ID
                </dt>
                <dd class="font-medium wrap-anywhere">
                  {{ record.id }}
                </dd>
              </div>
            </dl>
            <UButton
              v-if="record.observation_id"
              color="neutral"
              variant="outline"
              icon="i-lucide-external-link"
              @click="openObservation"
            >
              Open source observation
            </UButton>
          </UCard>
          <p v-if="confirmation" class="text-sm text-muted" role="status">
            {{ confirmation }}
          </p>
          <CaseFinance v-if="record.financial" :value="record.financial" />
          <CaseFiles
            :key="selectedPath + record.capabilities.join('|')"
            :path="selectedPath"
            :record="record"
            :permission="project.permission"
            @changed="emit('changed')"
            @session-expired="expire"
          />
          <div class="grid min-w-0 items-start gap-4 2xl:grid-cols-2 [&>:only-child]:col-span-full">
            <CaseActions
              :key="selectedPath"
              :path="selectedPath"
              :record="record"
              :permission="project.permission"
              @saved="savedAction"
              @session-expired="expire"
            />
            <CaseTimeline :events="record.events" :receipts="record.bank_receipts" />
          </div>
        </template>
      </div>
    </div>

    <CreateCaseModal
      v-if="canCreate && (newCase || linkedSource)"
      :key="project.id + ':' + (linkedSource ?? 'new')"
      :project="project"
      :source-id="linkedSource"
      @dismiss="dismissCreate"
      @created="savedCase"
      @session-expired="expire"
    />
  </section>
</template>
