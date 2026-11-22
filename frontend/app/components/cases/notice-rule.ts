export const deadlineModes = [
  { value: 'elapsed_hours', label: 'Elapsed hours' },
  { value: 'calendar_days', label: 'Calendar days' },
  { value: 'manual', label: 'Manual contract deadline' }
] as const

export type DeadlineMode = (typeof deadlineModes)[number]['value']

export type RuleFields = {
  agreement: string
  clause: string
  issuer_actor_id: string
  authority: string
  recipient: string
  service_method: string
  timezone: string
  trigger: string
}

export type NoticeRule = RuleFields & {
  version: number
  issuer_name: string
} & (
  { deadline_mode: 'elapsed_hours' | 'calendar_days', window: number }
  | { deadline_mode: 'manual', manual_instructions: string }
)

export type NoticeRuleSettings = {
  actor_id: string
  can_manage: boolean
  issuers: { id: string, name: string }[]
  rule: NoticeRule | null
}

export function noticeRulePath(project: string) {
  return '/api/projects/' + encodeURIComponent(project) + '/notice-rule'
}

export function describeDeadline(rule: NoticeRule) {
  switch (rule.deadline_mode) {
    case 'elapsed_hours':
      return `${rule.window} elapsed ${rule.window === 1 ? 'hour' : 'hours'} after the trigger`
    case 'calendar_days':
      return `End of the local day, ${rule.window} calendar ${rule.window === 1 ? 'day' : 'days'} after the trigger`
    case 'manual':
      return rule.manual_instructions
  }
}

export function formatNoticeDeadline(instant: string) {
  return instant.replace('T', ' ').replace(/Z$/, ' UTC')
}
