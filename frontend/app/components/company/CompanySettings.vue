<script setup lang="ts">
import CompanyAdmin from '~/components/company/CompanyAdmin.vue'

const { companies, loadCompanies } = useWorkspace()
const administrators = computed(() => companies.value.filter(company => company.role === 'admin'))
const selected = ref<string>()
const company = computed(() => administrators.value.find(item => item.id === selected.value) ?? administrators.value[0])
</script>

<template>
  <section v-if="company" class="mx-auto w-full max-w-6xl space-y-4">
    <div class="flex flex-wrap items-end justify-between gap-3">
      <div class="min-w-0">
        <h1 class="text-2xl font-semibold text-highlighted wrap-anywhere">
          {{ company.name }}
        </h1>
        <p class="text-sm text-muted">
          Set up projects and manage company access.
        </p>
      </div>
      <USelect
        v-if="administrators.length > 1"
        :model-value="company.id"
        :items="administrators.map(item => ({ label: item.name, value: item.id }))"
        aria-label="Company"
        @update:model-value="selected = $event"
      />
    </div>
    <CompanyAdmin :key="company.id" :company-id="company.id" />
  </section>
  <UAlert
    v-else
    title="Company settings are unavailable."
    description="Sign in as a company administrator to manage setup."
    variant="subtle"
  >
    <template #actions>
      <UButton
        color="neutral"
        variant="outline"
        label="Refresh companies"
        @click="loadCompanies"
      />
    </template>
  </UAlert>
</template>
