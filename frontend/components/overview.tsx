import { useEffect, useRef, useState } from 'react'
import { ArrowRight, ArrowUpRight, Banknote, CalendarClock, ClipboardList, FileText, GanttChartSquare } from 'lucide-react'
import { api, reportError, type Project } from '../lib/api'

type Day = { day: string; observations: number; cases: number }
type RecentCase = { id: string; title: string; recorded_at: string; notice_due_at: string | null; has_instruction: boolean }
type Notice = { case_id: string; title: string; reference: string; due_at: string }
type OverviewData = {
  open_cases: number
  without_instruction: number
  notices_due: number
  observations: number
  financial: null | { outstanding: string; certified: string; matched: string; retained: string; currency: 'ZAR'; basis: 'excl_vat' }
  activity: Day[]
  cases: RecentCase[]
  notices: Notice[]
}
type Period = 7 | 14 | 30

const shortDay = new Intl.DateTimeFormat('en-ZA', { month: 'short', day: 'numeric', timeZone: 'UTC' })
const fullDay = new Intl.DateTimeFormat('en-ZA', { dateStyle: 'medium', timeZone: 'UTC' })
const deadline = new Intl.DateTimeFormat('en-ZA', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' })
const integer = new Intl.NumberFormat('en-ZA')
function money(value: string) {
  const [whole, decimal] = value.split('.')
  return 'R ' + whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',') + (decimal ? '.' + decimal : '')
}

function ActivityChart({ activity }: { activity: Day[] }) {
  const canvas = useRef<HTMLCanvasElement>(null)
  useEffect(() => {
    const el = canvas.current
    const context = el?.getContext('2d')
    if (!el || !context) return

    function draw() {
      if (!el || !context) return
      const width = el.clientWidth
      const height = el.clientHeight
      if (!width || !height) return
      const scale = window.devicePixelRatio || 1
      el.width = Math.round(width * scale)
      el.height = Math.round(height * scale)
      context.setTransform(scale, 0, 0, scale, 0, 0)
      const left = 31
      const right = width - 14
      const top = 16
      const floor = height - 31
      const peak = Math.max(1, ...activity.map(({ observations, cases }) => Math.max(observations, cases)))
      const interval = Math.max(1, Math.ceil(peak / 4))
      const ceiling = interval * 4
      const x = (index: number) => left + index * (right - left) / Math.max(1, activity.length - 1)
      const y = (value: number) => floor - value * (floor - top) / ceiling

      context.font = '11px system-ui'
      context.fillStyle = '#a5acaa'
      context.textAlign = 'right'
      for (let tick = 0; tick <= 4; tick++) {
        const value = tick * interval
        context.fillText(String(value), left - 10, y(value) + 4)
        context.beginPath()
        context.moveTo(left, y(value) + 0.5)
        context.lineTo(right, y(value) + 0.5)
        context.strokeStyle = '#2a2f2e'
        context.lineWidth = 1
        context.stroke()
      }
      const ends = width < 455 ? 3 : 5
      for (let tick = 0; tick < ends; tick++) {
        const index = Math.round(tick * (activity.length - 1) / (ends - 1))
        const day = activity[index]
        if (!day) continue
        context.textAlign = tick === 0 ? 'left' : tick === ends - 1 ? 'right' : 'center'
        context.fillText(shortDay.format(new Date(day.day + 'T00:00:00Z')), x(index), height - 8)
      }

      const line = (key: 'observations' | 'cases') => {
        activity.forEach((day, index) => {
          if (index === 0) context.moveTo(x(index), y(day[key]))
          else context.lineTo(x(index), y(day[key]))
        })
      }
      if (activity.some((day) => day.observations)) {
        const gradient = context.createLinearGradient(0, top, 0, floor)
        gradient.addColorStop(0, 'rgba(51, 226, 166, .35)')
        gradient.addColorStop(1, 'rgba(51, 226, 166, .035)')
        context.beginPath()
        line('observations')
        context.lineTo(right, floor)
        context.lineTo(left, floor)
        context.closePath()
        context.fillStyle = gradient
        context.fill()
      }
      for (const [key, color] of [['observations', '#38e7ad'], ['cases', '#8b9fb1']] as const) {
        if (!activity.some((day) => day[key])) continue
        context.beginPath()
        line(key)
        context.lineJoin = 'round'
        context.lineWidth = key === 'observations' ? 2.25 : 1.5
        context.strokeStyle = color
        context.setLineDash(key === 'observations' ? [] : [4, 5])
        context.stroke()
      }
    }
    const observer = new ResizeObserver(draw)
    observer.observe(el)
    draw()
    return () => observer.disconnect()
  }, [activity])

  const opened = activity.reduce((sum, day) => sum + day.cases, 0)
  const recorded = activity.reduce((sum, day) => sum + day.observations, 0)
  return (
    <>
      <canvas className="activity-canvas" ref={canvas} role="img"
        aria-label={`Change activity, last ${activity.length} days: ${opened} cases opened and ${recorded} observations recorded`} />
      <details className="chart-values">
        <summary>Daily counts <span className="muted">(UTC)</span></summary>
        <table>
          <thead><tr><th scope="col">Date</th><th scope="col">Cases opened</th><th scope="col">Observations</th></tr></thead>
          <tbody>{activity.map((day) => (
            <tr key={day.day}><th scope="row">{day.day}</th><td>{day.cases}</td><td>{day.observations}</td></tr>
          ))}</tbody>
        </table>
      </details>
    </>
  )
}

type Props = {
  project: Project
  version: number
  onNewObservation: () => void
  onOpenCase: (id: string) => void
  onOpenRegister: () => void
  onSessionExpired: () => void
}

export function Overview({ project, version, onNewObservation, onOpenCase, onOpenRegister, onSessionExpired }: Props) {
  const [period, setPeriod] = useState<Period>(14)
  const [data, setData] = useState<OverviewData>()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [retry, setRetry] = useState(0)

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError('')
    api<OverviewData>(`/api/projects/${project.id}/overview?days=${period}`, { signal: controller.signal })
      .then((result) => { if (!controller.signal.aborted) setData(result) })
      .catch((cause: unknown) => {
        if (!controller.signal.aborted) {
          setData(undefined)
          setError(reportError(cause, onSessionExpired))
        }
      })
      .finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [project.id, version, period, retry, onSessionExpired])

  const metrics = data && [
    { key: 'open-cases', label: 'Open cases', value: integer.format(data.open_cases), detail: 'Cases in progress', icon: ClipboardList, color: '' },
    { key: 'instruction', label: 'Without instruction', value: integer.format(data.without_instruction), detail: 'Open cases without written direction', icon: GanttChartSquare, color: 'blue' },
    { key: 'notices', label: 'Notices due', value: integer.format(data.notices_due), detail: 'Overdue or due within 7 days', icon: CalendarClock, color: 'amber' },
    data.financial
      ? { key: 'outstanding', label: 'Net certified balance', value: money(data.financial.outstanding), detail: 'Receivables less credits, excl. VAT', icon: Banknote, color: '' }
      : { key: 'observations', label: 'Observations', value: integer.format(data.observations), detail: 'Recorded on this project', icon: FileText, color: '' },
  ]

  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Project overview</h1>
          <p className="muted">Change control and payment for {project.name}.</p>
        </div>
        {project.permission === 'capture' && <button className="button primary" onClick={onNewObservation}><FileText size={16} /> New observation</button>}
      </div>
      {!data && !error && <div className="panel inline-message" role="status">Loading project overview…</div>}
      {error && <div className="panel inline-message" role="alert"><p className="error">{error}</p><button className="button secondary" onClick={() => setRetry(retry + 1)}>Retry loading overview</button></div>}
      {data && metrics && (
        <>
          <dl className="metric-grid">
            {metrics.map(({ key, icon: Icon, label, value, detail, color }) => (
              <div className="metric" key={key} data-metric={key}>
                <dt className="metric-top"><span>{label}</span><span className={`metric-icon ${color}`}><Icon size={17} aria-hidden="true" /></span></dt>
                <dd><strong>{value}</strong><span className="metric-detail muted">{detail}</span></dd>
              </div>
            ))}
          </dl>

          <div className="overview-grid">
            <section className="panel activity-panel" aria-labelledby="activity-title">
              <div className="panel-heading">
                <div><h2 id="activity-title">Change activity</h2><p className="muted">Cases opened and observations recorded</p></div>
                <div className="period-buttons" aria-label="Activity range" role="group" aria-busy={loading}>
                  {([7, 14, 30] as const).map((days) => (
                    <button type="button" key={days} aria-pressed={period === days} onClick={() => setPeriod(days)}>{days} days</button>
                  ))}
                </div>
              </div>
              <ActivityChart activity={data.activity} />
              <div className="chart-legend"><span>Observations</span><span>Cases opened</span></div>
            </section>
            <section className="panel notice-panel" aria-labelledby="notice-title">
              <div className="panel-heading">
                <div><h2 id="notice-title">Notice deadlines</h2><p className="muted">Unsent notices due soon or overdue</p></div>
                <CalendarClock size={19} className="muted" aria-hidden="true" />
              </div>
              {data.notices.length === 0 && <p className="inline-message muted">No notices due in the next 7 days.</p>}
              <ul className="notice-list">
                {data.notices.map((notice, index) => (
                  <li key={`${notice.case_id}:${notice.reference}:${index}`}>
                    <button type="button" onClick={() => onOpenCase(notice.case_id)}>
                      <span className="notice-marker" aria-hidden="true" />
                      <span><strong>{notice.title}</strong><span className="muted">{notice.reference} · {deadline.format(new Date(notice.due_at)) + ' UTC'}</span></span>
                      <ArrowUpRight size={16} aria-hidden="true" />
                    </button>
                  </li>
                ))}
              </ul>
            </section>
          </div>

          <section className="panel register-panel" aria-labelledby="register-title">
            <div className="panel-heading">
              <h2 id="register-title">Recent open cases</h2>
              <button className="button secondary" type="button" onClick={onOpenRegister}>View case register <ArrowRight size={15} aria-hidden="true" /></button>
            </div>
            {data.cases.length === 0 ? <p className="inline-message muted">There are no open change cases on this project.</p> : (
              <div className="register-table-wrap">
                <table className="dashboard-table">
                  <thead><tr><th scope="col">Change case</th><th scope="col">Written instruction</th><th scope="col">Next notice deadline</th><th scope="col">Recorded</th></tr></thead>
                  <tbody>
                    {data.cases.map((row) => (
                      <tr key={row.id}>
                        <th scope="row"><a href={`?project=${project.id}&view=cases&caseId=${row.id}`} onClick={(event) => {
                          if (event.button === 0 && !event.altKey && !event.ctrlKey && !event.metaKey && !event.shiftKey) {
                            event.preventDefault()
                            onOpenCase(row.id)
                          }
                        }}>{row.title}</a></th>
                        <td><span className={`badge ${row.has_instruction ? 'good' : 'warn'}`}>{row.has_instruction ? 'On file' : 'Awaiting'}</span></td>
                        <td>{row.notice_due_at ? deadline.format(new Date(row.notice_due_at)) + ' UTC' : '—'}</td>
                        <td>{fullDay.format(new Date(row.recorded_at))}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
        </>
      )}
    </>
  )
}
