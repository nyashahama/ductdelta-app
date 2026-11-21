<script setup lang="ts">
import { api, reportError, requestJson, type Project } from '~/utils/api'

const props = defineProps<{ project: Project }>()
const emit = defineEmits<{
  close: []
  saved: [id: string]
  'session-expired': []
}>()

const capturedProject = props.project.id
const captureAllowed = computed(() => (
  props.project.id === capturedProject && props.project.permission === 'capture'
))
const note = ref('')
const location = ref('')
const observedAt = ref('')
const pending = ref(false)
const error = ref('')
let inFlight: AbortController | undefined
let submitted: { payload: string, id: string } | undefined

watch(captureAllowed, (allowed) => {
  if (allowed) return
  inFlight?.abort()
  emit('close')
}, { flush: 'sync' })
onScopeDispose(() => inFlight?.abort())

function close() {
  if (!pending.value) emit('close')
}

async function save() {
  if (!captureAllowed.value || pending.value) return
  if (!note.value.trim()) {
    error.value = 'Enter an observation.'
    return
  }

  const observed = observedAt.value ? new Date(observedAt.value) : null
  if (observed && (Number.isNaN(observed.getTime()) || !/^\d{4}-/.test(observedAt.value))) {
    error.value = 'Enter a valid time observed.'
    return
  }

  const values = {
    note: note.value,
    location: location.value.trim() ? location.value : null,
    observed_at: observed?.toISOString() ?? null
  }
  const payload = JSON.stringify(values)
  if (submitted?.payload !== payload) submitted = { payload, id: crypto.randomUUID() }

  const controller = new AbortController()
  inFlight = controller
  pending.value = true
  error.value = ''

  try {
    const { id } = await api<{ id: string }>(`/api/projects/${capturedProject}/observations`, {
      ...requestJson({ ...values, operation_id: submitted.id }),
      signal: controller.signal
    })
    if (!controller.signal.aborted) emit('saved', id)
  } catch (cause) {
    if (!controller.signal.aborted) {
      error.value = reportError(cause, () => emit('session-expired'))
    }
  } finally {
    if (inFlight === controller) {
      inFlight = undefined
      pending.value = false
    }
  }
}
</script>

<template>
  <UModal
    v-if="captureAllowed"
    :open="true"
    :dismissible="!pending"
    :close="false"
    title="New observation"
    :description="project.name"
    @update:open="(open) => { if (!open) close() }"
  >
    <template #body>
      <form class="space-y-4" @submit.prevent="save">
        <fieldset :disabled="pending" class="space-y-4">
          <UFormField label="Observation" name="note" required>
            <UTextarea v-model="note" class="w-full" required autofocus :rows="4" :maxlength="4000" />
          </UFormField>
          <UFormField label="Location" name="location">
            <UInput v-model="location" class="w-full" :maxlength="120" />
          </UFormField>
          <UFormField
            label="Time observed"
            name="observed_at"
            hint="Optional"
            description="Uses the time zone on this device."
          >
            <UInput v-model="observedAt" type="datetime-local" class="w-full" />
          </UFormField>
        </fieldset>
        <p v-if="error" class="text-sm text-error" role="alert">
          {{ error }}
        </p>
        <div class="flex flex-wrap justify-end gap-2">
          <UButton type="button" label="Cancel" color="neutral" variant="outline" :disabled="pending" @click="close" />
          <UButton type="submit" label="Save observation" :loading="pending" />
        </div>
      </form>
    </template>
  </UModal>
</template>
