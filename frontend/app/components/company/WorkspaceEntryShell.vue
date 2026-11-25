<script setup lang="ts">
defineProps<{ title: string }>()
</script>

<template>
  <main class="workspace-entry">
    <div class="workspace-entry-form">
      <section class="workspace-entry-content" aria-labelledby="workspace-gate-title">
        <WorkspaceBrand />
        <h1 id="workspace-gate-title">
          {{ title }}
        </h1>
        <slot />
      </section>
    </div>
    <div class="workspace-entry-art" aria-hidden="true" />
  </main>
</template>
