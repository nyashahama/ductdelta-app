import { ApiError, api, reportError, requestJson, type Project } from '~/utils/api'

export type WorkspaceView = 'overview' | 'observations' | 'cases'
type Session = { name: string }

export function useWorkspace() {
  const route = useRoute()
  const router = useRouter()
  const session = useState<Session | null | undefined>('workspace-session', () => undefined)
  const projects = useState<Project[] | undefined>('workspace-projects', () => undefined)
  const error = useState('workspace-error', () => '')
  const signInError = useState('workspace-sign-in-error', () => '')
  const signing = useState('workspace-signing', () => false)

  const requestedProject = computed(() => typeof route.query.project === 'string'
    ? route.query.project
    : route.query.project ? '' : undefined)
  const project = computed(() => requestedProject.value === undefined
    ? projects.value?.[0]
    : projects.value?.find(({ id }) => id === requestedProject.value))
  const unavailableProject = computed(() => projects.value !== undefined
    && requestedProject.value !== undefined && !project.value)
  const view = computed<WorkspaceView>(() => route.query.view === 'observations' || route.query.view === 'cases'
    ? route.query.view
    : 'overview')

  function target(next: WorkspaceView, projectId = project.value?.id ?? requestedProject.value, id?: string) {
    return {
      path: '/',
      query: {
        project: projectId,
        view: next === 'overview' ? undefined : next,
        caseId: next === 'cases' ? id : undefined,
        observationId: next === 'observations' ? id : undefined
      }
    }
  }

  function endSession(message = '') {
    session.value = null
    projects.value = undefined
    error.value = ''
    signInError.value = message
  }

  function expire() {
    endSession('Your session ended. Sign in again.')
  }

  async function loadProjects() {
    error.value = ''
    const current = session.value
    if (!current) return
    try {
      const list = await api<Project[]>('/api/projects')
      if (session.value === current) projects.value = list
    } catch (cause) {
      if (session.value === current) error.value = reportError(cause, expire)
    }
  }

  async function restoreSession() {
    if (session.value !== undefined) return
    try {
      session.value = await api<Session>('/api/session')
      await loadProjects()
    } catch (cause) {
      endSession(cause instanceof ApiError && cause.status === 401 ? '' : reportError(cause, expire))
    }
  }

  async function signIn(key: string) {
    if (signing.value) return
    signing.value = true
    signInError.value = ''
    try {
      await api<undefined>('/api/session', requestJson({ key }))
      session.value = await api<Session>('/api/session')
      await loadProjects()
    } catch (cause) {
      signInError.value = cause instanceof ApiError ? cause.message : 'Could not reach DuctDelta. Try again.'
    } finally {
      signing.value = false
    }
  }

  async function signOut() {
    if (signing.value) return
    signing.value = true
    error.value = ''
    try {
      await api<undefined>('/api/session', { method: 'DELETE' })
      endSession()
      await router.replace('/')
    } catch (cause) {
      error.value = reportError(cause, expire)
    } finally {
      signing.value = false
    }
  }

  return {
    session, project, projects, view, unavailableProject, error, signInError, signing,
    target, expire, loadProjects, restoreSession, signIn, signOut
  }
}
