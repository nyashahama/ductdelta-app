<script setup lang="ts">
import { ref } from 'vue'
import { api, reportError, requestJson, type Project } from '../../utils/api'
import { casePath, retryOperation, type Operation } from './case-data'
import { useActiveScope } from './useCaseResource'

const props = defineProps<{ project: Project, sourceId: string | null }>()
const emit = defineEmits<{ dismiss: [], created: [id: string], 'session-expired': [] }>()
const title = ref('')
const busy = ref(false)
const error = ref('')
const active = useActiveScope()
let operation: Operation | null = null

async function save() {
  if (busy.value || props.project.permission !== 'capture') return
  const name = title.value.trim()
  if (!name) {
    error.value = 'Enter a case title.'
    return
  }
  const body = props.sourceId ? { title: name, observation_id: props.sourceId } : { title: name }
  operation = retryOperation(operation, body)
  error.value = ''
  busy.value = true
  try {
    const result = await api<{ id: string }>(casePath(props.project.id), requestJson({ operation_id: operation.id, ...body }))
    if (active()) emit('created', result.id)
  } catch (problem) {
    if (active()) error.value = reportError(problem, () => emit('session-expired'))
  } finally {
    if (active()) busy.value = false
  }
}
</script>

<template>
  <UModal
    :open="true"
    :dismissible="!busy"
    :close="!busy"
    title="New change case"
    :description="project.name + (sourceId ? ' · Linked to this observation' : '')"
    @update:open="(value) => { if (!value && !busy) emit('dismiss') }"
  >
    <template #body>
      <form class="space-y-4" @submit.prevent="save">
        <UFormField label="Case title" name="title" required>
          <UInput v-model="title" class="w-full" name="title" aria-label="Case title" required :maxlength="160" :readonly="busy" autofocus />
        </UFormField>
        <p v-if="error" role="alert" class="text-sm text-error">
          {{ error }}
        </p>
        <div class="flex flex-wrap justify-end gap-2">
          <UButton color="neutral" variant="outline" :disabled="busy" @click="emit('dismiss')">
            Cancel
          </UButton>
          <UButton type="submit" :loading="busy">
            Create case
          </UButton>
        </div>
      </form>
    </template>
  </UModal>
</template>
