<script setup lang="ts">
import { useMediaQuery } from '@vueuse/core'
import type { FollowUpPage } from '~/types/overview'
import { api, reportError } from '~/utils/api'
import { followUpActions } from './follow-up-action'

const props = defineProps<{ project: string, version: number }>()
const emit = defineEmits<{ open: [id: string], register: [], observation: [id: string], sessionExpired: [] }>()
const page = ref(1)
const attempt = ref(0)
const result = shallowRef<FollowUpPage>()
const loading = ref(true)
const error = ref('')

const wide = useMediaQuery('(min-width: 64rem)')
const selectedId = ref<string>()
const selected = computed(() => result.value?.cases.find(item => item.id === selectedId.value) ?? result.value?.cases[0])

watch([page, attempt, () => props.version], async ([requestedPage], _, onCleanup) => {
  const controller = new AbortController()
  onCleanup(() => controller.abort())
  loading.value = true
  error.value = ''
  try {
    const list = await api<FollowUpPage>(`/api/projects/${props.project}/follow-ups?page=${requestedPage}`, { signal: controller.signal })
    if (controller.signal.aborted) return
    if (!list.cases.length && requestedPage > 1) {
      page.value = requestedPage - 1
      return
    }
    result.value = list
  } catch (cause) {
    if (controller.signal.aborted) return
    result.value = undefined
    error.value = reportError(cause, () => emit('sessionExpired'))
  } finally {
    if (!controller.signal.aborted) loading.value = false
  }
}, { immediate: true })
</script>

<template>
  <section
    aria-labelledby="change-follow-ups"
    :aria-busy="loading"
    class="min-w-0 shrink-0 overflow-hidden rounded-2xl border border-default bg-default shadow-sm"
  >
    <header data-follow-up-header class="relative isolate flex flex-wrap items-center justify-between gap-3 border-b border-default px-4 py-4 sm:px-6">
      <div class="flex min-w-0 items-center gap-3">
        <span class="grid size-9 shrink-0 place-items-center rounded-xl bg-primary/12 text-primary ring-1 ring-primary/25 sm:size-11">
          <UIcon name="i-lucide-list-checks" class="size-5" aria-hidden="true" />
        </span>
        <h2 id="change-follow-ups" class="text-lg leading-tight font-semibold tracking-tight text-highlighted sm:text-2xl">
          Change follow-ups
        </h2>
      </div>
      <UButton
        color="neutral"
        variant="outline"
        size="sm"
        aria-label="Case register"
        trailing-icon="i-lucide-arrow-up-right"
        class="rounded-lg bg-default"
        @click="emit('register')"
      >
        <span class="sm:hidden">Register</span>
        <span class="hidden sm:inline">Case register</span>
      </UButton>
    </header>

    <div v-if="error" class="p-4 sm:p-6">
      <UAlert
        role="alert"
        color="error"
        variant="subtle"
        :title="error"
      >
        <template #actions>
          <UButton
            color="neutral"
            variant="outline"
            label="Retry follow-ups"
            @click="attempt++"
          />
        </template>
      </UAlert>
    </div>
    <p v-else-if="!result" role="status" class="p-6 text-sm text-muted">
      Loading change follow-ups…
    </p>
    <div v-else-if="!result.cases.length" class="flex items-center gap-3 p-6">
      <span class="grid size-9 shrink-0 place-items-center rounded-full bg-primary/10 text-primary">
        <UIcon name="i-lucide-check" class="size-5" aria-hidden="true" />
      </span>
      <p class="text-sm font-medium text-highlighted">
        No open change cases to follow up.
      </p>
    </div>
    <div v-else class="lg:grid lg:grid-cols-[minmax(14rem,0.85fr)_minmax(0,2fr)]">
      <div class="min-w-0 bg-elevated/30 lg:border-e lg:border-default">
        <h3 class="px-4 pt-4 pb-2 text-xs font-semibold tracking-wide text-toned lg:px-5">
          Case queue
        </h3>
        <ul aria-label="Case queue" class="space-y-0.5 px-2 pb-3 sm:px-3">
          <li v-for="item in result.cases" :key="item.id" class="min-w-0">
            <button
              type="button"
              :aria-pressed="selected?.id === item.id"
              class="group flex w-full min-w-0 items-center gap-3 rounded-lg border border-transparent px-2.5 py-2 text-left transition-colors hover:bg-elevated focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-primary aria-pressed:border-primary/25 aria-pressed:bg-primary/10 sm:px-3"
              @click="selectedId = item.id"
            >
              <span :class="followUpActions[item.actions[0].kind].tone" class="grid size-8 shrink-0 place-items-center rounded-lg">
                <UIcon :name="followUpActions[item.actions[0].kind].icon" class="size-4" aria-hidden="true" />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block text-sm leading-5 font-medium wrap-anywhere text-highlighted">{{ item.title }}</span>
                <span class="block text-xs leading-5 text-muted">
                  {{ followUpActions[item.actions[0].kind].stage }}<template v-if="item.actions.length > 1"> · {{ item.actions.length }} actions</template>
                </span>
              </span>
              <UIcon
                :name="selected?.id === item.id && !wide ? 'i-lucide-chevron-down' : 'i-lucide-chevron-right'"
                class="size-4 shrink-0 text-dimmed group-aria-pressed:text-primary"
                aria-hidden="true"
              />
            </button>
            <div v-if="!wide && selected?.id === item.id" class="my-2 overflow-hidden rounded-xl border border-default">
              <HomeFollowUpDetail
                :project="project"
                :item="item"
                @open="emit('open', $event)"
                @observation="emit('observation', $event)"
              />
            </div>
          </li>
        </ul>
        <nav v-if="page > 1 || result.has_more" aria-label="Change follow-up pages" class="flex items-center justify-between gap-2 border-t border-default px-3 py-2.5">
          <UButton
            size="sm"
            color="neutral"
            variant="ghost"
            icon="i-lucide-chevron-left"
            :disabled="loading || page === 1"
            label="Previous"
            @click="page--"
          />
          <span class="text-xs text-muted" role="status">Page {{ page }}</span>
          <UButton
            size="sm"
            color="neutral"
            variant="ghost"
            trailing-icon="i-lucide-chevron-right"
            :disabled="loading || !result.has_more"
            label="Next"
            @click="page++"
          />
        </nav>
      </div>
      <HomeFollowUpDetail
        v-if="wide && selected"
        :project="project"
        :item="selected"
        @open="emit('open', $event)"
        @observation="emit('observation', $event)"
      />
    </div>
  </section>
</template>

<style scoped>
[data-follow-up-header] {
  background: linear-gradient(104deg, color-mix(in srgb, var(--ui-primary) 10%, var(--ui-bg)), var(--ui-bg) 65%);
}

[data-follow-up-header]::before {
  position: absolute;
  z-index: -1;
  inset: 0 0 0 30%;
  background-image: radial-gradient(color-mix(in srgb, var(--ui-primary) 32%, transparent) 0.7px, transparent 0.7px);
  background-size: 10px 10px;
  mask-image: linear-gradient(to left, #000 5%, transparent 96%);
  content: '';
  pointer-events: none;
}
</style>
