<script setup lang="ts">
import { workspaceMark } from '~/utils/brand'

const colorMode = useColorMode()
const color = computed(() => colorMode.value === 'dark' ? '#101a28' : '#f6f9fc')

useHead({
  title: 'DuctDelta Workspace',
  meta: [
    { charset: 'utf-8' },
    { name: 'viewport', content: 'width=device-width, initial-scale=1' },
    { key: 'theme-color', name: 'theme-color', content: color }
  ],
  htmlAttrs: { lang: 'en' },
  link: [{ rel: 'icon', href: workspaceMark, type: 'image/webp', sizes: '128x128' }]
})
</script>

<template>
  <UApp>
    <NuxtLoadingIndicator />
    <NuxtLayout>
      <NuxtPage />
    </NuxtLayout>
  </UApp>
</template>
