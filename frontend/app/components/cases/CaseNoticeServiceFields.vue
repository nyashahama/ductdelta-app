<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import CaseActionField from './CaseActionField.vue'
import { eventsOf, eventTitle, type CaseIssuedNoticeCopy, type CaseRecord } from './case-data'

const props = defineProps<{
  kind: 'notice_dispatch' | 'notice_receipt'
  record: CaseRecord
  copies: CaseIssuedNoticeCopy[]
  disabled: boolean
}>()
const noticeId = ref<string>()
const copyId = ref<string>()
const dispatchId = ref<string>()
const serviceMethod = ref('')
const notices = computed(() => eventsOf(props.record, 'notice').toReversed())
const noticesById = computed(() => new Map(notices.value.map(notice => [notice.id, notice])))
const noticeOptions = computed(() => notices.value.map(notice => ({ label: eventTitle(notice), value: notice.id })))
const noticeCopies = computed(() => props.copies
  .filter(copy => copy.notice_id === noticeId.value)
  .toSorted((first, second) => second.version - first.version))
const copyOptions = computed(() => noticeCopies.value.map(copy => ({
  label: `Version ${copy.version} · ${copy.recipient}`,
  value: copy.id
})))
const dispatches = computed(() => eventsOf(props.record, 'notice_dispatch').toReversed())
const dispatchOptions = computed(() => dispatches.value.map(event => ({
  label: eventTitle(event) + (event.data.copy ? ' · version ' + event.data.copy.version : ' · legacy notice'),
  value: event.id,
  notice: event.data.notice
})))
const correctionOptions = computed(() => dispatchOptions.value.filter(option => option.notice === noticeId.value))
const dispatch = computed(() => dispatches.value.find(event => event.id === dispatchId.value))
const copy = computed(() => noticeCopies.value.find(item => item.id === copyId.value))
const expectedMethod = computed(() => {
  const notice = noticeId.value ? noticesById.value.get(noticeId.value) : undefined
  return notice?.data.notice_rule?.service_method ?? ''
})
const needsEvidence = computed(() => expectedMethod.value !== '' && serviceMethod.value !== expectedMethod.value)

watch(noticeId, () => {
  copyId.value = undefined
})
watch(copyId, () => {
  serviceMethod.value = expectedMethod.value
})
</script>

<template>
  <template v-if="kind === 'notice_dispatch'">
    <UFormField label="Notice" name="notice" required>
      <USelect
        v-model="noticeId"
        aria-label="Notice"
        name="notice"
        :items="noticeOptions"
        :disabled="disabled"
        class="w-full"
        placeholder="Choose a notice"
        required
      />
    </UFormField>
    <UFormField
      v-if="noticeCopies.length"
      label="Issued copy"
      name="issued_copy"
      required
    >
      <USelect
        :key="noticeId"
        v-model="copyId"
        aria-label="Issued copy"
        name="issued_copy"
        :items="copyOptions"
        :disabled="disabled"
        class="w-full"
        placeholder="Choose the version sent"
        required
      />
    </UFormField>
    <template v-if="copy">
      <input type="hidden" name="recipient" :value="copy.recipient">
      <p class="text-sm wrap-anywhere">
        Recipient on this copy: {{ copy.recipient }}
      </p>
      <label class="flex gap-2 text-sm">
        <input
          :key="copy.id"
          type="checkbox"
          class="mt-0.5 size-4 accent-primary"
          required
        >
        Confirm this version was sent to the recipient shown
      </label>
      <UFormField label="Actual service method" name="service_method" required>
        <UInput
          v-model="serviceMethod"
          aria-label="Actual service method"
          name="service_method"
          :disabled="disabled"
          :maxlength="240"
          :placeholder="expectedMethod || undefined"
          class="w-full"
          required
        />
      </UFormField>
      <CaseActionField
        v-if="needsEvidence"
        :field="{ name: 'service_evidence', label: 'Service exception evidence', input: 'textarea', limit: 2000 }"
        :disabled="disabled"
      />
      <CaseActionField
        v-if="correctionOptions.length"
        :key="noticeId"
        :field="{ name: 'corrects_dispatch', label: 'Corrects earlier dispatch', options: correctionOptions, optional: true }"
        :disabled="disabled"
      />
    </template>
    <p v-else-if="noticeId && !noticeCopies.length" class="text-sm text-muted">
      This notice has no issued copy. You can record notice-level dispatch evidence.
    </p>
  </template>
  <template v-else>
    <UFormField label="Dispatch" name="dispatch" required>
      <USelect
        v-model="dispatchId"
        aria-label="Dispatch"
        name="dispatch"
        :items="dispatchOptions"
        :disabled="disabled"
        class="w-full"
        placeholder="Choose the dispatch acknowledged"
        required
      />
    </UFormField>
    <input
      v-if="dispatch"
      type="hidden"
      name="notice"
      :value="dispatch.data.notice"
    >
  </template>
  <CaseActionField
    :field="{ name: 'reference', label: kind === 'notice_dispatch' ? 'Dispatch reference' : 'Acknowledgement reference', limit: 160 }"
    :disabled="disabled"
  />
</template>
