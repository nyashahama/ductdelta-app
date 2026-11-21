export type ActivityDay = { day: string, observations: number, cases: number }
export type RecentCase = {
  id: string
  title: string
  recorded_at: string
  notice_due_at: string | null
  has_instruction: boolean
}
export type Notice = { case_id: string, title: string, reference: string, due_at: string }
export type Overview = {
  open_cases: number
  without_instruction: number
  notices_due: number
  observations: number
  financial: null | { outstanding: string, certified: string, matched: string, retained: string, currency: 'ZAR', basis: 'excl_vat' }
  activity: ActivityDay[]
  cases: RecentCase[]
  notices: Notice[]
}

const deadline = new Intl.DateTimeFormat('en-ZA', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' })
export function formatDeadline(value: string) {
  return deadline.format(new Date(value)) + ' UTC'
}
