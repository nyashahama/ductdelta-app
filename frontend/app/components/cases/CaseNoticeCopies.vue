<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { ApiError, api, reportError, requestJson } from '../../utils/api'
import { eventsOf, formatDate, type CaseIssuedNoticeCopy, type CaseRecord } from './case-data'
import { useActiveScope, useCaseResource } from './useCaseResource'

type RecipientLink = { id: string, expires_at: string, revoked_at: string | null }
type IssuedCopy = {
  id: string
  version: number
  supersedes: string | null
  recipient: string
  issued_at: string
  sha256: string
  link: RecipientLink | null
}
type NoticeCopies = { copies: IssuedCopy[], is_notice_issuer: boolean }
type IssueDraft = { operation_id: string, recipient: string, message: string, supersedes: string | null }
type LinkDraft = { copyId: string, operation_id: string, token: string }
type Rule = { recipient: string, clause: string, service_method: string, issuer_name: string }

const props = defineProps<{ path: string, record: CaseRecord, permission: 'read' | 'capture' }>()
const emit = defineEmits<{ 'session-expired': [], 'issued': [copy: CaseIssuedNoticeCopy] }>()
const expire = () => emit('session-expired')
const isActive = useActiveScope()
const notices = computed(() => eventsOf(props.record, 'notice'))
const choices = computed(() => notices.value.map(notice => ({ label: notice.data.reference, value: notice.id })))
const selectedId = ref<string>()
const selectedNotice = computed(() => notices.value.find(notice => notice.id === selectedId.value))
const rule = computed(() => {
  const data = selectedNotice.value?.data
  return data && 'notice_rule' in data ? data.notice_rule as Rule | undefined : undefined
})
const endpoint = computed(() => selectedNotice.value ? `${props.path}/notices/${selectedNotice.value.id}/copies` : null)
const { resource, reload } = useCaseResource<NoticeCopies>(endpoint, expire)
const noticeCopies = computed(() => resource.value.kind === 'ready' ? resource.value.data : null)
const dispatchedCopies = computed(() => new Set(eventsOf(props.record, 'notice_dispatch')
  .flatMap(event => event.data.copy ? [event.data.copy.id] : [])))
const versions = computed(() => noticeCopies.value?.copies ?? [])
const latest = computed(() => versions.value[0])
const canManage = computed(() => props.permission === 'capture' && props.record.capabilities.includes('direction'))
const canIssue = computed(() => canManage.value && !props.record.closed && noticeCopies.value?.is_notice_issuer)
const issuing = ref(false)
const recipient = ref('')
const message = ref('')
const pending = ref(false)
const error = ref('')
const feedback = ref('')
const visibleLink = ref<{ id: string, url: string }>()
let issueDraft: IssueDraft | undefined
let linkDraft: LinkDraft | undefined

watch(notices, (items) => {
  if (!items.some(notice => notice.id === selectedId.value)) selectedId.value = items[0]?.id
}, { immediate: true })

watch(endpoint, () => {
  issuing.value = false
  visibleLink.value = undefined
  pending.value = false
  error.value = ''
  feedback.value = ''
  issueDraft = undefined
  linkDraft = undefined
})

watch([recipient, message], () => {
  issueDraft = undefined
})

function openDraft() {
  recipient.value = rule.value?.recipient ?? latest.value?.recipient ?? ''
  message.value = ''
  feedback.value = ''
  error.value = ''
  issuing.value = true
}

function cancelDraft() {
  issueDraft = undefined
  issuing.value = false
  message.value = ''
}

function hasActiveLink(link: RecipientLink | null) {
  return Boolean(link && !link.revoked_at && new Date(link.expires_at).getTime() > Date.now())
}

async function issue() {
  if (pending.value || !endpoint.value || !canIssue.value || !recipient.value.trim() || !message.value.trim()) return
  const path = endpoint.value
  issueDraft ??= {
    operation_id: crypto.randomUUID(),
    recipient: rule.value?.recipient ?? recipient.value.trim(),
    message: message.value,
    supersedes: latest.value?.id ?? null
  }
  const isCurrent = () => isActive() && endpoint.value === path
  pending.value = true
  error.value = ''
  try {
    const saved = await api<IssuedCopy>(path, requestJson(issueDraft))
    if (!isCurrent()) return
    cancelDraft()
    feedback.value = `Version ${saved.version} issued.`
    if (selectedId.value) emit('issued', { ...saved, notice_id: selectedId.value })
    reload()
  } catch (cause) {
    if (isCurrent()) {
      if (cause instanceof ApiError && cause.status === 409) {
        issueDraft = undefined
        issuing.value = false
        reload()
        error.value = 'The saved copies changed. Review the latest version and open a new draft.'
      } else {
        error.value = reportError(cause, expire)
      }
    }
  } finally {
    if (isCurrent()) pending.value = false
  }
}

async function createLink(copy: IssuedCopy) {
  if (pending.value || !endpoint.value || !canManage.value) return
  const path = endpoint.value
  const isCurrent = () => isActive() && endpoint.value === path
  pending.value = true
  error.value = ''
  feedback.value = ''
  try {
    if (linkDraft?.copyId !== copy.id) {
      // Keep the same secret until the request succeeds so a lost reply can be retried.
      const bytes = crypto.getRandomValues(new Uint8Array(32))
      const token = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('')
      linkDraft = { copyId: copy.id, operation_id: crypto.randomUUID(), token }
    }
    const { operation_id, token } = linkDraft
    const link = await api<RecipientLink>(`${path}/${copy.id}/links`, requestJson({ operation_id, token }))
    if (!isCurrent()) return
    linkDraft = undefined
    if (hasActiveLink(link)) {
      visibleLink.value = { id: link.id, url: `${location.origin}/notice-copy#key=${token}` }
    }
    reload()
  } catch (cause) {
    if (isCurrent()) {
      error.value = reportError(cause, expire)
      if (cause instanceof ApiError && cause.status === 409) {
        linkDraft = undefined
        reload()
      }
    }
  } finally {
    if (isCurrent()) pending.value = false
  }
}

async function revokeLink(copy: IssuedCopy, link: RecipientLink) {
  if (pending.value || !endpoint.value || !canManage.value) return
  const path = endpoint.value
  const isCurrent = () => isActive() && endpoint.value === path
  pending.value = true
  error.value = ''
  feedback.value = ''
  try {
    await api(`${path}/${copy.id}/links/${link.id}`, { method: 'DELETE' })
    if (!isCurrent()) return
    if (visibleLink.value?.id === link.id) visibleLink.value = undefined
    reload()
  } catch (cause) {
    if (isCurrent()) error.value = reportError(cause, expire)
  } finally {
    if (isCurrent()) pending.value = false
  }
}

async function copyLink(url: string) {
  try {
    await navigator.clipboard.writeText(url)
    if (isActive() && visibleLink.value?.url === url) feedback.value = 'Recipient link copied.'
  } catch {
    if (isActive() && visibleLink.value?.url === url) feedback.value = 'Select the link and copy it manually.'
  }
}
</script>

<template>
  <UCard
    v-if="selectedNotice"
    as="section"
    aria-label="Issued notice copies"
    class="min-w-0"
    :ui="{ header: 'px-4 py-3 sm:px-4', body: 'space-y-4 p-4 sm:p-4' }"
  >
    <template #header>
      <h3 class="font-semibold text-highlighted">
        Issued notice copies
      </h3>
    </template>
    <UFormField label="Recorded notice">
      <USelect
        v-model="selectedId"
        :items="choices"
        class="w-full sm:w-64"
        :disabled="pending"
      />
    </UFormField>
    <p v-if="resource.kind === 'loading'" class="text-sm text-muted" role="status">
      Loading issued copies…
    </p>
    <div v-else-if="resource.kind === 'error'" class="space-y-2">
      <p class="text-sm text-error" role="alert">
        {{ resource.message }}
      </p>
      <UButton color="neutral" variant="outline" @click="reload">
        Reload issued copies
      </UButton>
    </div>
    <template v-else>
      <p v-if="!versions.length" class="text-sm text-muted">
        No copies have been issued for this notice.
      </p>
      <p v-if="canManage && !record.closed && !noticeCopies?.is_notice_issuer" class="text-sm text-muted">
        The recorded issuer can issue a copy for this notice.
      </p>
      <UButton
        v-if="canIssue && !issuing"
        icon="i-lucide-file-check"
        color="neutral"
        variant="outline"
        :disabled="pending"
        @click="openDraft"
      >
        {{ latest ? 'Issue a new version' : 'Issue a copy' }}
      </UButton>
      <form v-if="issuing && canIssue" class="space-y-4 rounded-lg border border-default p-4" @submit.prevent="issue">
        <dl class="flex flex-wrap gap-x-5 gap-y-2 text-sm">
          <div>
            <dt class="text-xs text-muted">
              Agreement
            </dt>
            <dd class="wrap-anywhere">
              {{ selectedNotice.data.agreement }}
            </dd>
          </div>
          <div v-if="rule">
            <dt class="text-xs text-muted">
              Clause
            </dt>
            <dd class="wrap-anywhere">
              {{ rule.clause }}
            </dd>
          </div>
          <div v-if="rule">
            <dt class="text-xs text-muted">
              Issuer
            </dt>
            <dd class="wrap-anywhere">
              {{ rule.issuer_name }}
            </dd>
          </div>
          <div v-if="rule">
            <dt class="text-xs text-muted">
              Required service method
            </dt>
            <dd class="wrap-anywhere">
              {{ rule.service_method }}
            </dd>
          </div>
          <div v-if="selectedNotice.data.due_at">
            <dt class="text-xs text-muted">
              Notice deadline
            </dt>
            <dd>{{ selectedNotice.data.due_at }}</dd>
          </div>
        </dl>
        <UFormField label="Recipient" required>
          <UInput
            v-model="recipient"
            required
            :maxlength="250"
            class="w-full"
            :readonly="Boolean(rule)"
            :disabled="pending"
          />
        </UFormField>
        <UFormField label="Recipient-facing text" required>
          <UTextarea
            v-model="message"
            required
            :maxlength="12000"
            :rows="5"
            class="w-full"
            :disabled="pending"
          />
        </UFormField>
        <p class="text-sm text-muted">
          Check that the recipient can see every detail in this text. Issuing saves an exact copy. Record dispatch and acknowledgement separately.
        </p>
        <p v-if="latest" class="text-sm text-muted">
          This copy supersedes version {{ latest.version }}. Any link to the earlier copy stays valid until it expires or you revoke it.
        </p>
        <div class="flex flex-wrap gap-2">
          <UButton type="submit" :disabled="!recipient.trim() || !message.trim()" :loading="pending">
            Issue version {{ (latest?.version ?? 0) + 1 }}
          </UButton>
          <UButton
            color="neutral"
            variant="ghost"
            :disabled="pending"
            @click="cancelDraft"
          >
            Cancel
          </UButton>
        </div>
      </form>
      <ol v-if="versions.length" class="divide-y divide-default rounded-lg border border-default">
        <li v-for="copy in versions" :key="copy.id" class="space-y-2 p-3">
          <div class="flex flex-wrap items-center gap-2">
            <h4 class="font-medium text-highlighted">
              Version {{ copy.version }}
            </h4>
            <UBadge v-if="latest?.id !== copy.id" color="neutral" variant="subtle">
              Superseded
            </UBadge>
          </div>
          <p class="text-sm wrap-anywhere">
            Issued to {{ copy.recipient }} <span class="text-muted">· {{ formatDate(copy.issued_at) }}</span>
          </p>
          <p class="text-sm text-muted">
            {{ dispatchedCopies.has(copy.id) ? 'Dispatch recorded for this version' : copy.id === latest?.id
              ? 'Latest version has no dispatch record' : 'No dispatch recorded for this version' }}
          </p>
          <p class="text-xs text-muted">
            SHA-256 <code class="wrap-anywhere">{{ copy.sha256 }}</code>
          </p>
          <div class="flex flex-wrap gap-2">
            <UButton
              external
              :to="`${endpoint}/${copy.id}/download`"
              color="neutral"
              variant="outline"
              size="sm"
              icon="i-lucide-download"
            >
              Download version {{ copy.version }}
            </UButton>
            <UButton
              v-if="canManage && copy.link && hasActiveLink(copy.link)"
              color="neutral"
              variant="ghost"
              size="sm"
              :disabled="pending"
              @click="revokeLink(copy, copy.link)"
            >
              Revoke recipient link for version {{ copy.version }}
            </UButton>
            <UButton
              v-else-if="canManage"
              color="neutral"
              variant="ghost"
              size="sm"
              :disabled="pending"
              @click="createLink(copy)"
            >
              Create recipient link for version {{ copy.version }}
            </UButton>
          </div>
          <p v-if="copy.link" class="text-sm text-muted">
            {{ copy.link.revoked_at ? 'Recipient link revoked' : hasActiveLink(copy.link)
              ? 'Recipient link expires ' + formatDate(copy.link.expires_at) : 'Recipient link expired' }}
          </p>
          <template v-if="visibleLink && copy.link?.id === visibleLink.id && hasActiveLink(copy.link)">
            <div class="flex flex-wrap items-end gap-2">
              <UFormField :label="'Recipient link for version ' + copy.version" class="min-w-0 flex-1">
                <UInput :model-value="visibleLink.url" readonly class="w-full" />
              </UFormField>
              <UButton color="neutral" variant="outline" @click="copyLink(visibleLink.url)">
                Copy link
              </UButton>
            </div>
            <p class="text-sm text-muted">
              Anyone with this link can download this version for seven days. Share it with {{ copy.recipient }} using the agreed service method.
            </p>
          </template>
        </li>
      </ol>
    </template>
    <p v-if="feedback" class="text-sm text-muted" role="status">
      {{ feedback }}
    </p>
    <p v-if="error" class="text-sm text-error" role="alert">
      {{ error }}
    </p>
  </UCard>
</template>
