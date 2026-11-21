<script setup lang="ts">
import { api, reportError, requestJson } from '~/utils/api'
import type { Access, Capability, CompanyProject, Member } from '~/components/company/access'

const props = defineProps<{ member: Member, path: string, projects: CompanyProject[], access: Access[] }>()
const emit = defineEmits<{ close: [], changed: [] }>()
const { expire } = useWorkspace()
const role = ref(props.member.role)
const selectedProject = ref<string>()
const permission = ref<'none' | 'read' | 'capture'>('none')
const capabilities = ref<Capability[]>([])
const removing = ref(false)
const pending = ref(false)
const error = ref('')
const receipt = ref('')
const memberPath = computed(() => props.path + '/members/' + props.member.id)

const roleItems = [
  { label: 'Team member', value: 'member' },
  { label: 'Company administrator', value: 'admin' }
]
const permissionItems = [
  { label: 'No access', value: 'none' },
  { label: 'Read', value: 'read' },
  { label: 'Capture', value: 'capture' }
]
const capabilityItems = [
  { label: 'Directions and notices', value: 'direction' },
  { label: 'Quotes and commercial decisions', value: 'commercial' },
  { label: 'Certificates, payments and finance files', value: 'finance' }
]

function selectProject(projectId: string) {
  selectedProject.value = projectId
  const entry = props.access.find(item => item.project_id === projectId && item.actor_id === props.member.id)
  permission.value = entry?.permission ?? 'none'
  capabilities.value = [...(entry?.capabilities ?? [])]
  receipt.value = ''
}

async function save(path: string, request: RequestInit, message: string) {
  if (pending.value) return
  pending.value = true
  error.value = ''
  receipt.value = ''
  try {
    await api(path, request)
    receipt.value = message
    removing.value = false
    emit('changed')
  } catch (cause) {
    error.value = reportError(cause, expire)
  } finally {
    pending.value = false
  }
}

function saveProject() {
  if (!selectedProject.value) return
  return save(props.path + '/projects/' + selectedProject.value + '/members/' + props.member.id, {
    ...requestJson({
      permission: permission.value === 'none' ? null : permission.value,
      capabilities: permission.value === 'none' ? [] : capabilities.value
    }),
    method: 'PUT'
  }, 'Project access saved.')
}
</script>

<template>
  <UModal
    :open="true"
    :dismissible="!pending"
    title="Manage access"
    :description="member.name"
    @update:open="open => { if (!open) emit('close') }"
  >
    <template #body>
      <div class="space-y-5">
        <UAlert
          v-if="error"
          role="alert"
          color="error"
          variant="subtle"
          :title="error"
        />
        <p v-if="receipt" role="status" class="text-sm text-success">
          {{ receipt }}
        </p>
        <template v-if="receipt !== 'Company access removed.'">
          <form class="space-y-3" @submit.prevent="save(memberPath, { ...requestJson({ role }), method: 'PUT' }, 'Company role saved.')">
            <UFormField label="Company role" name="member-role">
              <USelect
                v-model="role"
                :items="roleItems"
                class="w-full"
                :disabled="pending"
              />
            </UFormField>
            <UButton
              type="submit"
              label="Save company role"
              color="neutral"
              variant="outline"
              :disabled="pending || role === member.role"
            />
          </form>
          <USeparator />
          <form v-if="projects.length" class="space-y-3" @submit.prevent="saveProject">
            <UFormField label="Project" name="access-project">
              <USelect
                :model-value="selectedProject"
                :items="projects.map(project => ({ value: project.id, label: project.name }))"
                placeholder="Select a project"
                aria-label="Project"
                class="w-full"
                :disabled="pending"
                @update:model-value="selectProject"
              />
            </UFormField>
            <template v-if="selectedProject">
              <UFormField label="Project permission" name="permission">
                <USelect
                  v-model="permission"
                  :items="permissionItems"
                  aria-label="Project permission"
                  class="w-full"
                  :disabled="pending"
                />
              </UFormField>
              <UFormField v-if="permission !== 'none'" label="Workflow permissions" name="capabilities">
                <UCheckboxGroup v-model="capabilities" :items="capabilityItems" :disabled="pending" />
              </UFormField>
              <UButton type="submit" label="Save project access" :disabled="pending" />
            </template>
          </form>
          <p v-else class="text-sm text-muted">
            Create a project before assigning project access.
          </p>
          <USeparator />
          <UButton
            v-if="!removing"
            label="Remove from company"
            color="error"
            variant="outline"
            :disabled="pending"
            @click="removing = true"
          />
          <template v-else>
            <p class="text-sm text-muted">
              Remove {{ member.name }} from all projects in this company?
            </p>
            <div class="flex flex-wrap gap-2">
              <UButton
                label="Confirm removal"
                color="error"
                :loading="pending"
                @click="save(memberPath, { method: 'DELETE' }, 'Company access removed.')"
              />
              <UButton
                label="Cancel"
                color="neutral"
                variant="outline"
                :disabled="pending"
                @click="removing = false"
              />
            </div>
          </template>
        </template>
      </div>
    </template>
  </UModal>
</template>
