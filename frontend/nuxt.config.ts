export default defineNuxtConfig({
  modules: ['@nuxt/eslint', '@nuxt/ui', '@vueuse/nuxt'],
  devtools: { enabled: false },
  app: { head: { title: 'DuctDelta Workspace', htmlAttrs: { lang: 'en' } } },
  css: ['~/assets/css/main.css'],
  colorMode: { preference: 'dark', fallback: 'dark' },
  ui: {
    fonts: false,
    eslint: {
      rules: {
        'no-unknown-classes': 'error',
        'no-conflicting-classes': 'error',
        'no-palette-colors': 'error'
      }
    }
  },
  experimental: { appManifest: false, payloadExtraction: false },
  compatibilityDate: '2026-06-30',
  eslint: { config: { stylistic: { commaDangle: 'never', braceStyle: '1tbs' } } },
  icon: {
    mode: 'svg',
    clientBundle: { scan: true, includeCustomCollections: true },
    provider: 'none'
  }
})
