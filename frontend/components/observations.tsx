import { useEffect, useRef, useState, type FormEvent } from 'react'
import { FilePlus2 } from 'lucide-react'
import { api, reportError, requestJson, type Project } from '../lib/api'

type ObservationSummary = { id: string; note_preview: string; location: string | null; recorded_at: string }
type Observation = ObservationSummary & { note: string; actor_id: string; observed_at: string | null }
type ObservationPage = { observations: ObservationSummary[]; next: string | null }
const date = new Intl.DateTimeFormat('en-ZA', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' })

type WorkspaceProps = {
  project: Project
  observationId?: string
  version: number
  onSelect: (id: string) => void
  onSourceCase: (id: string) => void
  onCapture: () => void
  onSessionExpired: () => void
}

export function Observations({ project, observationId, version, onSelect, onSourceCase, onCapture, onSessionExpired }: WorkspaceProps) {
  const [rows, setRows] = useState<ObservationSummary[]>()
  const [next, setNext] = useState<string | null>(null)
  const [continuing, setContinuing] = useState(false)
  const [listError, setListError] = useState('')
  const [retry, setRetry] = useState(0)
  const [detail, setDetail] = useState<Observation>()
  const [detailError, setDetailError] = useState('')
  const path = `/api/projects/${project.id}/observations`

  useEffect(() => {
    const controller = new AbortController()
    api<ObservationPage>(path, { signal: controller.signal }).then((page) => {
      if (controller.signal.aborted) return
      setRows(page.observations)
      setNext(page.next)
    }).catch((error: unknown) => {
      if (!controller.signal.aborted) setListError(reportError(error, onSessionExpired))
    })
    return () => controller.abort()
  }, [path, retry, version, onSessionExpired])

  useEffect(() => {
    if (!observationId) return
    const controller = new AbortController()
    setDetailError('')
    api<Observation>(`${path}/${observationId}`, { signal: controller.signal })
      .then((record) => { if (!controller.signal.aborted) setDetail(record) })
      .catch((error: unknown) => {
        if (!controller.signal.aborted) setDetailError(reportError(error, onSessionExpired))
      })
    return () => controller.abort()
  }, [path, observationId, onSessionExpired])

  async function loadOlder() {
    if (!next || continuing) return
    setContinuing(true)
    setListError('')
    try {
      const page = await api<ObservationPage>(`${path}?before=${next}`)
      setRows((current) => [...(current ?? []), ...page.observations])
      setNext(page.next)
    } catch (error) {
      setListError(reportError(error, onSessionExpired))
    } finally {
      setContinuing(false)
    }
  }

  return (
    <>
      <div className="page-heading">
        <div><h1>Observations</h1><p className="muted">Record and review site changes as they happen.</p></div>
        {project.permission === 'capture' && <button className="button primary" onClick={onCapture}><FilePlus2 size={16} aria-hidden /> New observation</button>}
      </div>
      <div className="observation-grid">
        <section className="panel" aria-labelledby="log-title">
          <div className="panel-heading"><h2 id="log-title">Observation log</h2></div>
          {!rows && !listError && <p className="inline-message muted" role="status">Loading observations…</p>}
          {rows?.length === 0 && <p className="inline-message muted">No observations have been recorded.</p>}
          <ul className="observation-list">
            {rows?.map((row) => (
              <li key={row.id}>
                <button type="button" aria-pressed={observationId === row.id} onClick={() => onSelect(row.id)}>
                  <span>{row.note_preview || "Open observation"}</span>
                  <span className="muted">{row.location ? row.location + ' · ' : ''}{date.format(new Date(row.recorded_at))} UTC</span>
                </button>
              </li>
            ))}
          </ul>
          {listError && <p className="inline-message error" role="alert">{listError}</p>}
          {(next || (!rows && listError)) && (
            <div className="panel-footer">
              <button className="button secondary" disabled={continuing} onClick={() => {
                if (next) void loadOlder()
                else { setListError(''); setRetry((value) => value + 1) }
              }}>{next ? (continuing ? 'Loading…' : 'Load earlier observations') : 'Retry loading observations'}</button>
            </div>
          )}
        </section>
        <section className="panel" aria-labelledby="observation-title">
          <div className="panel-heading"><h2 id="observation-title">Observation record</h2></div>
          <div className="inline-message observation-detail">
            {!observationId && <p className="muted">Select an observation to read its full record.</p>}
            {detailError && <p className="error" role="alert">{detailError}</p>}
            {observationId && detail?.id !== observationId && !detailError && <p className="muted" role="status">Loading observation…</p>}
            {observationId && detail?.id === observationId && !detailError && (
              <>
                <p className="observation-note">{detail.note}</p>
                <dl>
                  <div><dt>Location</dt><dd>{detail.location || 'Not recorded'}</dd></div>
                  <div><dt>Observed</dt><dd>{detail.observed_at ? date.format(new Date(detail.observed_at)) + ' UTC' : 'Not recorded'}</dd></div>
                  <div><dt>Recorded</dt><dd>{date.format(new Date(detail.recorded_at))} UTC</dd></div>
                  <div><dt>Recorded by</dt><dd>{detail.actor_id}</dd></div>
                  <div><dt>Record ID</dt><dd>{detail.id}</dd></div>
                </dl>
                {project.permission === 'capture'
                  && <button className="button secondary" onClick={() => onSourceCase(detail.id)}>Create linked case</button>}
              </>
            )}
          </div>
        </section>
      </div>
    </>
  )
}

export function CaptureObservation({ project, onClose, onSaved, onSessionExpired }: {
  project: Project
  onClose: () => void
  onSaved: (id: string) => void
  onSessionExpired: () => void
}) {
  const dialog = useRef<HTMLDialogElement>(null)
  const submitted = useRef<{ payload: string; id: string } | null>(null)
  const busy = useRef(false)
  const inFlight = useRef<AbortController>(null)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    dialog.current?.showModal()
    return () => inFlight.current?.abort()
  }, [])

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (busy.current) return
    const fields = new FormData(event.currentTarget)
    const note = String(fields.get('note'))
    if (!note.trim()) { setError('Enter an observation.'); return }
    const location = String(fields.get('location'))
    const observed = String(fields.get('observed_at'))
    const values = {
      note, location: location || null,
      observed_at: observed ? new Date(observed).toISOString() : null,
    }
    const payload = JSON.stringify(values)
    if (submitted.current?.payload !== payload) submitted.current = { payload, id: crypto.randomUUID() }
    const controller = new AbortController()
    inFlight.current = controller
    busy.current = true
    setPending(true)
    setError('')
    try {
      const { id } = await api<{ id: string }>(`/api/projects/${project.id}/observations`, {
        ...requestJson({ ...values, operation_id: submitted.current.id }),
        signal: controller.signal,
      })
      if (!controller.signal.aborted) onSaved(id)
    } catch (cause) {
      if (!controller.signal.aborted) setError(reportError(cause, onSessionExpired))
    } finally {
      if (!controller.signal.aborted) {
        busy.current = false
        setPending(false)
      }
    }
  }

  return (
    <dialog ref={dialog} aria-labelledby="capture-title" onCancel={(event) => {
      event.preventDefault()
      if (!busy.current) onClose()
    }}>
      <div className="panel-heading"><div><h2 id="capture-title">New observation</h2><p className="muted">{project.name}</p></div></div>
      <form className="dialog-form" onSubmit={save}>
        <fieldset disabled={pending}>
          <label className="form-field" htmlFor="observation-note">Observation
            <textarea id="observation-note" name="note" required autoFocus rows={4} maxLength={4000} />
          </label>
          <label className="form-field" htmlFor="observation-location">Location
            <input id="observation-location" name="location" maxLength={120} />
          </label>
          <label className="form-field" htmlFor="observation-time">Time observed
            <input id="observation-time" name="observed_at" type="datetime-local" />
            <span className="muted">Uses the time zone on this device. Leave empty if the time is unknown.</span>
          </label>
        </fieldset>
        {error && <p className="error" role="alert">{error}</p>}
        <div className="dialog-actions">
          <button type="button" className="button secondary" disabled={pending} onClick={onClose}>Cancel</button>
          <button className="button primary" disabled={pending} type="submit">{pending ? 'Saving…' : 'Save observation'}</button>
        </div>
      </form>
    </dialog>
  )
}
