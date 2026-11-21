import { computed, onMounted, onScopeDispose, ref, shallowRef, toValue, watchEffect, type MaybeRefOrGetter } from 'vue'
import { api, reportError } from '../../utils/api'

type Resource<T> =
  | { kind: 'loading' }
  | { kind: 'ready', data: T }
  | { kind: 'error', message: string }

export function useCaseResource<T>(path: MaybeRefOrGetter<string | null>, expire: () => void) {
  const started = ref(false)
  const version = ref(0)
  const result = shallowRef<{ path: string, version: number, resource: Resource<T> } | null>(null)
  onMounted(() => { started.value = true })

  watchEffect((cleanup) => {
    const endpoint = toValue(path)
    const revision = version.value
    if (!started.value || !endpoint) return
    const request = new AbortController()
    cleanup(() => request.abort())
    void api<T>(endpoint, { signal: request.signal }).then((data) => {
      if (!request.signal.aborted) result.value = { path: endpoint, version: revision, resource: { kind: 'ready', data } }
    }).catch((error: unknown) => {
      if (request.signal.aborted) return
      const message = reportError(error, expire)
      if (message) result.value = { path: endpoint, version: revision, resource: { kind: 'error', message } }
    })
  })

  const resource = computed<Resource<T>>(() => {
    const entry = result.value
    return entry && entry.path === toValue(path) && entry.version === version.value ? entry.resource : { kind: 'loading' }
  })
  return { resource, reload: () => { version.value++ } }
}

export function useActiveScope() {
  let active = true
  onScopeDispose(() => { active = false })
  return () => active
}
