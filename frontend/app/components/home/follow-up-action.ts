import type { FollowUpAction } from '~/types/overview'

const notice = 'bg-amber-100 text-amber-800 dark:bg-amber-400/12 dark:text-amber-300'
const scope = 'bg-sky-100 text-sky-800 dark:bg-sky-400/12 dark:text-sky-300'
const commercial = 'bg-violet-100 text-violet-800 dark:bg-violet-400/12 dark:text-violet-300'
const payment = 'bg-green-100 text-green-800 dark:bg-green-400/12 dark:text-green-300'
const neutral = 'bg-muted text-toned'

export const followUpActions = {
  notice: { label: 'Send or record notice dispatch', stage: 'Notice to dispatch', icon: 'i-lucide-bell', tone: notice },
  revised_notice: { label: 'Send or record dispatch of revised notice', stage: 'Revised notice', icon: 'i-lucide-bell', tone: notice },
  instruction: { label: 'Confirm written instruction', stage: 'Written instruction', icon: 'i-lucide-file-warning', tone: scope },
  quote: { label: 'Prepare quote', stage: 'Quote to prepare', icon: 'i-lucide-file-text', tone: commercial },
  quote_decision: { label: 'Follow up on quote decision', stage: 'Quote decision', icon: 'i-lucide-file-check', tone: commercial },
  quote_lines: { label: 'Resolve open or disputed quote lines', stage: 'Open quote lines', icon: 'i-lucide-list-checks', tone: commercial },
  uncertified: { label: 'Review value still to certify', stage: 'Certification', icon: 'i-lucide-clipboard-list', tone: scope },
  application: { label: 'Check certification of payment application', stage: 'Certification', icon: 'i-lucide-clipboard-list', tone: scope },
  collect: { label: 'Check certified payment', stage: 'Payment to check', icon: 'i-lucide-banknote', tone: payment },
  credit: { label: 'Reconcile certificate credit', stage: 'Certificate credit', icon: 'i-lucide-banknote', tone: payment },
  retention: { label: 'Track retention release', stage: 'Retention held', icon: 'i-lucide-lock-keyhole', tone: notice },
  unallocated: { label: 'Match cash receipts', stage: 'Cash to match', icon: 'i-lucide-banknote', tone: payment },
  review: { label: 'Review open case', stage: 'Case review', icon: 'i-lucide-folder', tone: neutral }
} satisfies Record<FollowUpAction['kind'], { label: string, stage: string, icon: string, tone: string }>
