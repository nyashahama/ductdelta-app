import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import { ChevronDown, ClipboardList, FileText, LayoutGrid, LogOut, PanelLeft } from 'lucide-react'
import { ApiError, api, reportError, requestJson, type Project } from '../lib/api'
import CasesWorkspace from '../components/cases'
import { Overview } from '../components/overview'
import { CaptureObservation, Observations } from '../components/observations'

export type WorkspaceSearch = {
  project?: string
  view?: 'observations' | 'cases'
  caseId?: string
  observationId?: string
}
type Session = { name: string }
type WorkspaceProps = { search: WorkspaceSearch; navigate: (search: WorkspaceSearch) => void }

const navigation = [
  { label: 'Overview', view: undefined, Icon: LayoutGrid },
  { label: 'Observations', view: 'observations', Icon: FileText },
  { label: 'Change cases', view: 'cases', Icon: ClipboardList },
] as const

function Brand() {
  return <div className="brand"><span className="brand-mark" aria-hidden="true">Δ</span><span>DuctDelta</span></div>
}

function href(search: WorkspaceSearch) {
  const query = new URLSearchParams()
  if (search.project) query.set('project', search.project)
  if (search.view) query.set('view', search.view)
  return query.size ? '?' + query.toString() : '/'
}

export function Workspace({ search, navigate }: WorkspaceProps) {
  const [session, setSession] = useState<Session | null>()
  const [projects, setProjects] = useState<Project[]>()
  const [error, setError] = useState('')
  const [loginError, setLoginError] = useState('')
  const [signing, setSigning] = useState(false)
  const [retry, setRetry] = useState(0)
  const [captureProject, setCaptureProject] = useState<string>()
  const [source, setSource] = useState<{ project: string; id: string }>()
  const [version, setVersion] = useState(0)
  const [railOpen, setRailOpen] = useState(false)
  const content = useRef<HTMLElement>(null)

  const initial = useRef(true)
  const endSession = useCallback((message = '') => {
    initial.current = false
    setSession(null)
    setCaptureProject(undefined)
    setSource(undefined)
    setProjects(undefined)
    setError('')
    setLoginError(message)
  }, [])
  const expire = useCallback(() => endSession('Your session ended. Sign in again.'), [endSession])
  const changed = useCallback(() => setVersion((value) => value + 1), [])

  useEffect(() => {
    if (!initial.current) return
    const controller = new AbortController()
    api<Session>('/api/session', { signal: controller.signal })
      .then((value) => { if (!controller.signal.aborted) setSession(value) })
      .catch((cause) => {
        if (controller.signal.aborted) return
        endSession(cause instanceof ApiError && cause.status === 401 ? '' : reportError(cause, expire))
      })
    return () => controller.abort()
  }, [endSession, expire])

  useEffect(() => {
    if (!session) return
    const controller = new AbortController()
    api<Project[]>('/api/projects', { signal: controller.signal })
      .then((list) => { if (!controller.signal.aborted) setProjects(list) })
      .catch((cause) => { if (!controller.signal.aborted) setError(reportError(cause, expire)) })
    return () => controller.abort()
  }, [session, retry, expire])

  async function signIn(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (signing) return
    const form = event.currentTarget
    const key = new FormData(form).get('key')
    setSigning(true)
    setLoginError('')
    try {
      await api<void>('/api/session', requestJson({ key }))
      setSession(await api<Session>('/api/session'))
    } catch (cause) {
      setLoginError(cause instanceof ApiError ? cause.message : 'Could not reach DuctDelta. Try again.')
    } finally {
      form.reset()
      setSigning(false)
    }
  }

  async function signOut() {
    if (signing) return
    setSigning(true)
    setError('')
    try {
      await api<void>('/api/session', { method: 'DELETE' })
      endSession()
      navigate({})
    } catch (cause) {
      setError(reportError(cause, expire))
    } finally {
      setSigning(false)
    }
  }

  if (session === undefined) return <p className="startup" role="status">Opening DuctDelta…</p>

  if (!session) {
    return (
      <main className="sign-in">
        <section className="panel login-card" aria-labelledby="login-title">
          <Brand />
          <h1 id="login-title">Sign in to your workspace</h1>
          <p className="muted">Use your access key to open your projects.</p>
          <form onSubmit={signIn}>
            <label className="form-field" htmlFor="access-key">Access key
              <input id="access-key" name="key" type="password" autoComplete="current-password" required readOnly={signing} />
            </label>
            {loginError && <p className="error" role="alert">{loginError}</p>}
            <button className="button primary" type="submit" disabled={signing}>{signing ? 'Signing in…' : 'Sign in'}</button>
          </form>
        </section>
      </main>
    )
  }

  const project = search.project
    ? projects?.find((candidate) => candidate.id === search.project)
    : projects?.[0]
  const unavailableProject = Boolean(projects && search.project && !project)
  const heading = navigation.find((tab) => tab.view === search.view)?.label ?? 'Overview'
  const initials = session.name.trim().split(/\s+/).slice(0, 2).map((name) => name.charAt(0)).join('').toUpperCase()

  const openCase = (id: string) => {
    setSource(undefined)
    navigate({ project: project?.id, view: 'cases', caseId: id })
  }
  const openObservation = (id: string) => navigate({ project: project?.id, view: 'observations', observationId: id })
  const beginCapture = () => { if (project?.permission === 'capture') setCaptureProject(project.id) }

  return (
    <div className="workspace-layout" data-rail-open={railOpen || undefined}>
      <a href="#workspace-content" className="skip-link">Skip to workspace</a>
      <aside className="rail">
        <Brand />
        <label className="project-picker" htmlFor="workspace-project">
          <span className="muted">Project</span>
          <span>
            <select id="workspace-project" disabled={!projects?.length || signing} value={project?.id ?? ''}
              onChange={(event) => {
                setCaptureProject(undefined)
                setSource(undefined)
                navigate({ project: event.currentTarget.value, view: search.view })
              }}>
              {!project && <option value="" disabled>{projects?.length ? 'Select a project' : projects ? 'No assigned projects' : 'Loading projects…'}</option>}
              {projects?.map((choice) => <option key={choice.id} value={choice.id}>{choice.name}</option>)}
            </select>
            <ChevronDown size={16} aria-hidden="true" />
          </span>
        </label>
        <nav aria-label="Workspace" id="workspace-navigation">
          {navigation.map(({ view, label, Icon }) => {
            const target = { project: project?.id ?? search.project, view }
            return <a key={label} href={href(target)} aria-current={search.view === view ? 'page' : undefined}
              onClick={(event) => {
                if (event.button !== 0 || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return
                event.preventDefault()
                setSource(undefined)
                setRailOpen(false)
                navigate(target)
                content.current?.focus()
              }}><Icon size={17} aria-hidden="true" />{label}</a>
          })}
        </nav>
        <div className="rail-account">
          <span className="avatar" aria-hidden="true">{initials}</span>
          <span className="account-name">{session.name}</span>
          <button className="icon-button" type="button" aria-label="Sign out" title="Sign out" disabled={signing} onClick={signOut}><LogOut size={17} aria-hidden="true" /></button>
        </div>
      </aside>

      <div className="workspace-main">
        <header className="topbar">
          <button type="button" className="icon-button toggle-rail" aria-label="Workspace navigation"
            aria-expanded={railOpen} aria-controls="workspace-navigation" onClick={() => setRailOpen(!railOpen)}><PanelLeft size={18} aria-hidden="true" /></button>
          <div className="breadcrumbs"><span className="muted">{project?.name || 'Workspace'}</span><span aria-hidden="true">/</span><strong>{heading}</strong></div>
          <button className="icon-button mobile-sign-out" type="button" aria-label="Sign out" title="Sign out" disabled={signing} onClick={signOut}><LogOut size={17} aria-hidden="true" /></button>
        </header>

        <main id="workspace-content" className="workspace-content" ref={content} tabIndex={-1}>
          {error && <div className="panel inline-message" role="alert"><p className="error">{error}</p>
            {!projects && <button className="button secondary" onClick={() => { setError(''); setRetry(retry + 1) }}>Retry loading projects</button>}</div>}
          {!project && !unavailableProject && !error && <p className="inline-message muted" role="status">{projects ? 'Your account has no assigned projects.' : 'Loading projects…'}</p>}
          {unavailableProject && <p className="panel inline-message error" role="alert">This project is unavailable. Select a project to continue.</p>}
          {project && (!search.view
            ? <Overview key={project.id} project={project} version={version} onNewObservation={beginCapture}
                onOpenCase={openCase} onOpenRegister={() => navigate({ project: project.id, view: 'cases' })} onSessionExpired={expire} />
            : search.view === 'observations'
              ? <Observations key={project.id} project={project} version={version} observationId={search.observationId}
                  onSelect={openObservation} onCapture={beginCapture} onSessionExpired={expire} onSourceCase={(id) => {
                    setSource({ project: project.id, id })
                    navigate({ project: project.id, view: 'cases' })
                  }} />
              : <CasesWorkspace key={project.id} project={project} selectedCaseId={search.caseId ?? null}
                  sourceObservationId={source?.project === project.id ? source.id : null} onSelectCase={openCase}
                  onOpenObservation={openObservation} onChanged={changed} onSessionExpired={expire} />)}
        </main>

        {project?.permission === 'capture' && captureProject === project.id
          && <CaptureObservation key={project.id} project={project} onClose={() => setCaptureProject(undefined)} onSessionExpired={expire}
              onSaved={(id) => { setCaptureProject(undefined); changed(); openObservation(id) }} />}
      </div>
    </div>
  )
}
