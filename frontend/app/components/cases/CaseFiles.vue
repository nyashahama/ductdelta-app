<script setup lang="ts">
import { computed, ref } from 'vue'
import { api, reportError } from '../../utils/api'
import { formatDate, retryOperation, type CaseRecord, type Operation } from './case-data'
import { useActiveScope, useCaseResource } from './useCaseResource'

type CaseFile = {
  id: string
  filename: string
  media_type: string
  caption: string | null
  access_class: 'site' | 'finance'
  byte_size: number
  recorded_at: string
}

const props = defineProps<{ path: string, record: CaseRecord, permission: 'read' | 'capture' }>()
const emit = defineEmits<{ 'changed': [], 'session-expired': [] }>()
const extensions: Partial<Record<string, string>> = {
  pdf: 'application/pdf', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', txt: 'text/plain'
}
const mediaNames = new Map([
  ['application/pdf', 'PDF'], ['image/png', 'PNG'], ['image/jpeg', 'JPEG'], ['text/plain', 'Text file']
])
const sizeFormatter = new Intl.NumberFormat('en-GB', { maximumFractionDigits: 1 })
const filesPath = computed(() => props.path + '/files')
const expire = () => emit('session-expired')
const { resource, reload } = useCaseResource<CaseFile[]>(filesPath, expire)
const finance = computed(() => props.record.capabilities.includes('finance'))
const choices = computed(() => finance.value
  ? [{ label: 'Site team', value: 'site' }, { label: 'Finance only', value: 'finance' }]
  : [{ label: 'Site team', value: 'site' }])
const picker = ref<HTMLInputElement>()
const upload = ref<HTMLDetailsElement>()
const caption = ref('')
const access = ref('site')
const error = ref('')
const confirmation = ref('')
const busy = ref(false)
const active = useActiveScope()
let selectedFile: File | null = null
let operation: Operation | null = null

function fileSize(bytes: number) {
  if (bytes < 1024) return bytes + (bytes === 1 ? ' byte' : ' bytes')
  if (bytes < 1024 * 1024) return sizeFormatter.format(bytes / 1024) + ' KiB'
  return sizeFormatter.format(bytes / (1024 * 1024)) + ' MiB'
}

async function save() {
  if (busy.value || props.record.closed || props.permission !== 'capture') return
  const file = picker.value?.files?.[0]
  if (!file) return
  const suffix = file.name.match(/\.([^.]+)$/)?.[1]?.toLowerCase()
  const media = file.type.toLowerCase() || (suffix ? extensions[suffix] : undefined)
  error.value = ''
  confirmation.value = ''
  if (!file.size) error.value = 'Choose a file that is not empty.'
  else if (file.size > 5 * 1024 * 1024) error.value = 'Choose a file up to 5 MiB.'
  else if (!media || !mediaNames.has(media)) error.value = 'Choose a PDF, PNG, JPEG or TXT file.'
  if (!media || error.value) {
    picker.value?.focus()
    return
  }

  const visibility = finance.value && access.value === 'finance' ? 'finance' : 'site'
  const description = caption.value.trim()
  if (selectedFile !== file) {
    selectedFile = file
    operation = null
  }
  operation = retryOperation(operation, { visibility, description })
  busy.value = true

  try {
    const headers = new Headers({
      'Content-Type': media,
      'X-Operation-Id': operation.id,
      'X-File-Name': encodeURIComponent(file.name),
      'X-File-Access': visibility
    })
    if (description) headers.set('X-File-Caption', encodeURIComponent(description))
    await api(filesPath.value, { method: 'POST', headers, body: file })
    if (!active()) return
    selectedFile = null
    operation = null
    if (picker.value) picker.value.value = ''
    caption.value = ''
    access.value = 'site'
    if (upload.value) upload.value.open = false
    upload.value?.querySelector<HTMLElement>('summary')?.focus()
    confirmation.value = file.name + ' uploaded.'
    reload()
    emit('changed')
  } catch (problem) {
    if (active()) error.value = reportError(problem, expire)
  } finally {
    if (active()) busy.value = false
  }
}
</script>

<template>
  <UCard as="section" aria-label="Original case files" :ui="{ header: 'px-4 py-3 sm:px-4', body: 'p-0 sm:p-0' }">
    <template #header>
      <h3 class="font-semibold text-highlighted">
        Original case files
      </h3>
    </template>

    <p v-if="resource.kind === 'loading'" class="p-4 text-sm text-muted" role="status">
      Loading files…
    </p>
    <div v-else-if="resource.kind === 'error'" class="space-y-3 p-4">
      <p role="alert" class="text-sm text-error">
        {{ resource.message }}
      </p>
      <UButton color="neutral" variant="outline" @click="reload">
        Reload files
      </UButton>
    </div>
    <ul v-else-if="resource.data.length" class="divide-y divide-default">
      <li v-for="file in resource.data" :key="file.id" class="flex items-start justify-between gap-3 px-4 py-3">
        <div class="min-w-0 space-y-1">
          <p class="font-medium wrap-anywhere text-highlighted">
            {{ file.filename }}
          </p>
          <p class="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted">
            <UBadge :color="file.access_class === 'finance' ? 'warning' : 'neutral'" variant="subtle">
              {{ file.access_class === 'finance' ? 'Finance' : 'Site' }}
            </UBadge>
            <span>{{ mediaNames.get(file.media_type) ?? file.media_type }}</span>
            <span>{{ fileSize(file.byte_size) }}</span>
            <time :datetime="file.recorded_at">{{ formatDate(file.recorded_at) }}</time>
          </p>
          <p v-if="file.caption" class="text-sm wrap-anywhere whitespace-pre-wrap text-muted">
            {{ file.caption }}
          </p>
        </div>
        <UButton
          external
          :to="filesPath + '/' + encodeURIComponent(file.id)"
          color="neutral"
          variant="outline"
          icon="i-lucide-download"
          :aria-label="`Download ${file.filename}`"
        >
          Download
        </UButton>
      </li>
    </ul>
    <p v-else class="p-4 text-sm text-muted">
      No original files have been added.
    </p>

    <details v-if="permission === 'capture' && !record.closed" ref="upload" class="border-t border-default px-4 py-3">
      <summary class="cursor-pointer text-sm font-semibold text-primary">
        Add a file
      </summary>
      <form class="mt-4 space-y-4" @submit.prevent="save">
        <fieldset class="min-w-0 space-y-4" :disabled="busy">
          <div class="space-y-1.5 text-sm">
            <label for="case-upload-file" class="block font-medium text-highlighted">Original file</label>
            <input
              id="case-upload-file"
              ref="picker"
              type="file"
              class="block w-full min-w-0 cursor-pointer rounded-md ring ring-default file:me-2 file:cursor-pointer file:border-0 file:bg-elevated file:px-3 file:py-2 file:text-highlighted"
              required
              aria-describedby="case-upload-help"
              accept=".pdf,.png,.jpg,.jpeg,.txt,application/pdf,image/png,image/jpeg,text/plain"
            >
            <p id="case-upload-help" class="text-muted">
              PDF, PNG, JPEG or TXT. Maximum 5 MiB.
            </p>
          </div>
          <div class="grid gap-3 sm:grid-cols-2">
            <UFormField label="Caption" hint="Optional">
              <UInput
                v-model="caption"
                class="w-full"
                aria-label="Caption"
                :disabled="busy"
              />
            </UFormField>
            <UFormField label="File visibility">
              <USelect
                v-model="access"
                class="w-full"
                aria-label="File visibility"
                :items="choices"
                :disabled="busy"
              />
            </UFormField>
          </div>
        </fieldset>
        <p v-if="error" role="alert" class="text-sm text-error">
          {{ error }}
        </p>
        <UButton type="submit" :loading="busy">
          Upload file
        </UButton>
      </form>
    </details>
    <p v-if="confirmation" class="px-4 pb-3 text-sm" role="status">
      {{ confirmation }}
    </p>
  </UCard>
</template>
