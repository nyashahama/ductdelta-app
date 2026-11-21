import { ApiError, api, reportError, requestJson, type Project } from '~/utils/api'

export type WorkspaceView = 'overview' | 'observations' | 'cases' | 'company'
export type Company = { id: string, name: string, role: 'admin' | 'member' }
type Session = { name: string }

export function useWorkspace() {
  const route = useRoute()
  const router = useRouter()
  const session = useState<Session | null | undefined>('workspace-session', () => undefined)
  const companies = useState<Company[]>('workspace-companies', () => [])
  const projects = useState<Project[] | undefined>('workspace-projects', () => undefined)
  const error = useState('workspace-error', () => '')
  const signInError = useState('workspace-sign-in-error', () => '')
  const sessionCheckError = useState('workspace-session-check-error', () => '')
  const signing = useState('workspace-signing', () => false)

  const requestedProject = computed(() => typeof route.query.project === 'string'
    ? route.query.project
    : route.query.project ? '' : undefined)
  const project = computed(() => requestedProject.value === undefined
    ? projects.value?.[0]
    : projects.value?.find(({ id }) => id === requestedProject.value))
  const unavailableProject = computed(() => projects.value !== undefined
    && requestedProject.value !== undefined && !project.value)
  const view = computed<WorkspaceView>(() => route.query.view === 'observations' || route.query.view === 'cases' || route.query.view === 'company'
    ? route.query.view
    : 'overview')

  function target(next: WorkspaceView, projectId = project.value?.id ?? requestedProject.value, id?: string) {
    return {
      path: '/',
      query: {
        project: next === 'company' ? undefined : projectId,
        view: next === 'overview' ? undefined : next,
        caseId: next === 'cases' ? id : undefined,
        observationId: next === 'observations' ? id : undefined
      }
    }
  }

  function endSession(message = '') {
    session.value = null
    projects.value = undefined
    companies.value = []
    error.value = ''
    signInError.value = message
    sessionCheckError.value = ''
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

  async function loadCompanies() {
    const current = session.value
    if (!current) return
    try {
      const result = await api<Company[]>('/api/companies')
      if (session.value === current) companies.value = result
    } catch (cause) {
      if (session.value === current) error.value = reportError(cause, expire)
    }
  }

  async function refreshSession() {
    session.value = await api<Session>('/api/session')
    sessionCheckError.value = ''
    await Promise.all([loadProjects(), loadCompanies()])
  }

  async function restoreSession() {
    if (session.value !== undefined && !sessionCheckError.value) return
    try {
      await refreshSession()
    } catch (cause) {
      const message = cause instanceof ApiError && cause.status === 401 ? '' : reportError(cause, expire)
      endSession(message)
      sessionCheckError.value = message
    }
  }

  async function signIn(key: string) {
    if (signing.value) return false
    signing.value = true
    signInError.value = ''
    try {
      await api<undefined>('/api/session', requestJson({ key }))
      await refreshSession()
      return true
    } catch (cause) {
      signInError.value = cause instanceof ApiError ? cause.message : 'Could not reach DuctDelta. Try again.'
      return false
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
    session, companies, project, projects, view, unavailableProject, error, signInError, sessionCheckError, signing,
    target, expire, loadProjects, loadCompanies, refreshSession, restoreSession, signIn, signOut
  }
}
