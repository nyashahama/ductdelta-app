import { dispositions, eventsOf, eventTitle, formatDecimal, outcomes, unreversedAllocations, type ActionKind, type CaseEvent, type CaseRecord } from './case-data'
import type { NoticeRule } from './notice-rule'

export type Choice = { value: string, label: string }
export type ActionField = {
  name: string
  label: string
  input?: 'money' | 'textarea' | 'datetime-local' | 'timestamp'
  optional?: boolean
  value?: string
  options?: Choice[]
  limit?: number
  readonly?: boolean
}

export const dispositionChoices = dispositions.map(([value, label]) => ({ value, label }))

const text = (name: string, label: string, limit = 160): ActionField => ({ name, label, limit })
const paragraph = (name: string, label: string, limit: number, optional = false): ActionField => ({
  name, label, input: 'textarea', limit, optional
})
const money = (name: string, label: string, value?: string): ActionField => ({ name, label, input: 'money', value })
const reference = (label: string) => text('reference', label)

function linked(name: string, label: string, events: CaseEvent[], settings: Pick<ActionField, 'optional' | 'value'> = {}): ActionField {
  return { name, label, options: [...events].reverse().map(event => ({ value: event.id, label: eventTitle(event) })), ...settings }
}

export function actionFields(kind: ActionKind, record: CaseRecord, rule?: NoticeRule): ActionField[] {
  const agreement = { ...text('agreement', 'Agreement reference'), value: record.agreement ?? undefined, readonly: !!record.agreement }
  switch (kind) {
    case 'notice':
      if (rule) {
        return [
          reference('Notice reference'),
          paragraph('body', 'Notice text', 12000),
          { name: 'trigger_at', label: 'Trigger date, time and offset', input: 'timestamp', limit: 40 },
          ...(rule.deadline_mode === 'manual'
            ? [
                { name: 'due_at', label: 'Deadline date, time and offset', input: 'timestamp' as const, limit: 40 },
                paragraph('deadline_basis', 'How the deadline was determined', 4000)
              ]
            : [])
        ]
      }
      return [reference('Notice reference'), agreement, paragraph('body', 'Notice text', 12000),
        { name: 'due_at', label: 'Due date and time', input: 'datetime-local', optional: true }]
    case 'notice_dispatch':
    case 'notice_receipt':
      return []
    case 'instruction':
      return [reference('Instruction reference'), agreement, paragraph('scope', 'Authorized scope', 8000)]
    case 'work':
      return [paragraph('description', 'Work performed', 8000), linked('instruction', 'Instruction', eventsOf(record, 'instruction'), { optional: true }),
        { name: 'completed', label: 'Work status', options: [{ value: 'false', label: 'In progress' }, { value: 'true', label: 'Complete' }] }]
    case 'quote':
      return [reference('Quote reference')]
    case 'decision': {
      const quote = eventsOf(record, 'quote').at(-1)
      return quote ? [linked('quote', 'Quote', [quote], { value: quote.id }), paragraph('reason', 'Decision reason', 4000)] : []
    }
    case 'application':
      return [reference('Application reference'), money('amount', 'Applied amount')]
    case 'certificate': {
      const latest = eventsOf(record, 'certificate').at(-1)
      return [
        reference('Certificate reference'),
        ...(latest ? [linked('predecessor', 'Previous certificate', [latest], { value: latest.id })] : []),
        linked('application', 'Payment application', eventsOf(record, 'application'), { optional: true }),
        money('cumulative', 'Cumulative certified amount'), money('withheld', 'Retention withheld this period', '0'),
        money('released', 'Retention released this period', '0'), paragraph('reason', 'Reason', 4000, true)
      ]
    }
    case 'receipt':
      return [reference('Receipt reference'), money('amount', 'Receipt amount')]
    case 'allocate': {
      const receipts = record.bank_receipts.filter(receipt => Number(receipt.available) > 0).map(receipt => ({
        value: receipt.id,
        label: receipt.case_id === record.id
          ? 'Receipt ' + receipt.reference
          : 'Receipt ' + receipt.reference + ' · ' + receipt.project_name + ' / ' + receipt.case_title
            + ' · R' + formatDecimal(receipt.available) + ' available'
      }))
      const certificates = eventsOf(record, 'certificate').filter(event => record.allocatable_certificates.includes(event.id))
      return [{ name: 'receipt', label: 'Cash receipt', options: receipts }, linked('certificate', 'Certificate', certificates),
        money('amount', 'Allocation amount'), reference('Allocation reference')]
    }
    case 'reverse_allocation':
      return [linked('allocation', 'Allocation', unreversedAllocations(record)), paragraph('reason', 'Reversal reason', 4000)]
    case 'reopen':
      return [paragraph('reason', 'Reopening reason', 4000)]
    case 'close':
      return [{ name: 'outcome', label: 'Outcome', options: outcomes.map(([value, label]) => ({ value, label })) },
        paragraph('reason', 'Closeout reason', 4000)]
  }
}
