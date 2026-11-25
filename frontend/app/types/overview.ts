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

export type FollowUpAction
  = | { kind: 'review' }
    | { kind: 'notice' | 'revised_notice', reference: string, due_at: string | null, notice_id: string, copy_id: string | null, version: number | null }
    | { kind: 'instruction' | 'quote' }
    | { kind: 'quote_decision', amount: string, reference: string }
    | { kind: 'quote_lines', count: number }
    | { kind: 'uncertified', amount: string, reference: string | null }
    | { kind: 'application', reference: string }
    | { kind: 'collect' | 'credit' | 'retention' | 'unallocated', amount: string }

export type FollowUpCase = {
  id: string
  title: string
  actions: [FollowUpAction, ...FollowUpAction[]]
  evidence: {
    observation_id: string | null
    references: { kind: 'instruction' | 'quote' | 'application' | 'certificate', reference: string }[]
    unpaid_certificates: string[]
    file_count: number
    files: { id: string, filename: string, access_class: 'site' | 'finance' }[]
  }
}

export type FollowUpPage = { cases: FollowUpCase[], has_more: boolean }

const deadline = new Intl.DateTimeFormat('en-ZA', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' })
export function formatDeadline(value: string) {
  return deadline.format(new Date(value)) + ' UTC'
}
