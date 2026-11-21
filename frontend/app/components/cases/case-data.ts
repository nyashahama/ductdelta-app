export const actions = {
  notice: { label: "Record notice", grant: "direction", event: "Notice" },
  notice_dispatch: { label: "Record notice dispatch", grant: "direction", event: "Notice dispatched" },
  notice_receipt: { label: "Record notice acknowledgement", grant: "direction", event: "Notice acknowledged" },
  instruction: { label: "Record instruction", grant: "direction", event: "Instruction" },
  work: { label: "Record work", grant: "capture", event: "Work record" },
  quote: { label: "Record quote", grant: "commercial", event: "Quote" },
  decision: { label: "Decide quote", grant: "commercial", event: "Quote decision" },
  application: { label: "Record payment application", grant: "commercial", event: "Payment application" },
  certificate: { label: "Record certificate", grant: "finance", event: "Certificate" },
  receipt: { label: "Record cash receipt", grant: "finance", event: "Receipt" },
  allocate: { label: "Allocate receipt", grant: "finance", event: "Receipt allocation" },
  reverse_allocation: { label: "Reverse allocation", grant: "finance", event: "Allocation reversal" },
  close: { label: "Close case", grant: "commercial", event: "Closeout" },
} as const;

export const moneyLabels = {
  proposed: "Proposed", agreed: "Agreed", unresolved: "Unresolved",
  certified: "Certified", retained: "Retention held", payable: "Payable",
  matched: "Cash matched", outstanding: "Outstanding", unallocated: "Unallocated cash",
} as const;

export const dispositions = [
  ["open", "Open"], ["disputed", "Disputed"], ["waived", "Remainder waived"], ["accepted", "Accepted in full"],
] as const;
export const outcomes = [
  ["settled", "Settled"], ["no_change", "No change"], ["withdrawn", "Withdrawn"], ["rejected", "Rejected"],
] as const;

export type ActionKind = keyof typeof actions;
type Capability = "direction" | "commercial" | "finance";
type Disposition = (typeof dispositions)[number][0];
type Outcome = (typeof outcomes)[number][0];
export type MoneyField = keyof typeof moneyLabels;
export type FinancialPosition = Record<MoneyField, string | null> & { currency: string; basis: string; quote_awaiting_decision?: boolean };

export type QuoteLine = { description: string; amount: string };
type DecisionLine = { line: number; accepted: string; disposition: Disposition };
type Reference = { reference: string };
type Reason = { reason: string };
type Agreement = { agreement: string };
type EventPayload = {
  notice: Reference & Agreement & { body: string; due_at?: string };
  notice_dispatch: Reference & { notice: string };
  notice_receipt: Reference & { notice: string };
  instruction: Reference & Agreement & { scope: string };
  work: { description: string; completed: boolean; instruction?: string };
  quote: Reference & { lines: QuoteLine[] };
  decision: Reason & { quote: string; lines: DecisionLine[] };
  application: Reference & { amount: string };
  certificate: Reference & { cumulative: string; withheld: string; released: string; predecessor?: string; application?: string; reason?: string };
  receipt: Reference & { amount: string };
  allocate: Reference & { receipt: string; certificate: string; amount: string };
  reverse_allocation: Reason & { allocation: string };
  close: Reason & { outcome: Outcome };
};

export type CaseEvent = {
  [K in ActionKind]: {
    id: string;
    kind: K;
    recorded_at: string;
    actor_id: string;
    data: EventPayload[K] & { financial_snapshot?: Partial<Record<MoneyField | "work_delta", string | null>> };
  };
}[ActionKind];

export type CaseSummary = { id: string; title: string; closed: boolean };
export type CasePage = { cases: CaseSummary[]; next_before: string | null };
export type CaseRecord = CaseSummary & {
  agreement: string | null;
  observation_id: string | null;
  capabilities: Capability[];
  events: CaseEvent[];
  financial: FinancialPosition | null;
};

export function casePath(project: string, id?: string) {
  const root = "/api/projects/" + encodeURIComponent(project) + "/cases";
  return id ? root + "/" + encodeURIComponent(id) : root;
}

export function eventsOf<K extends ActionKind>(record: CaseRecord, kind: K) {
  return record.events.filter((event): event is Extract<CaseEvent, { kind: K }> => event.kind === kind);
}

export function unreversedAllocations(record: CaseRecord) {
  const reversed = new Set(eventsOf(record, "reverse_allocation").map((event) => event.data.allocation));
  return eventsOf(record, "allocate").filter((event) => !reversed.has(event.id));
}

export function eventTitle(event: CaseEvent) {
  const title = actions[event.kind].event;
  return "reference" in event.data ? title + " " + event.data.reference : title;
}

export function availableActions(record: CaseRecord, permission: "read" | "capture") {
  const grants = new Set<string>(record.capabilities);
  if (permission === "capture") grants.add("capture");
  return (Object.keys(actions) as ActionKind[]).filter((kind) => {
    const { grant } = actions[kind];
    if (!grants.has(grant)) return false;
    if (kind === "reverse_allocation") return unreversedAllocations(record).length > 0;
    if (record.closed) return false;
    if (kind === "notice_dispatch") return eventsOf(record, "notice").length > 0;
    if (kind === "notice_receipt") return eventsOf(record, "notice_dispatch").length > 0;
    if (kind === "close") return true;
    if ((grant === "commercial" || grant === "finance") && !record.agreement) return false;
    if (kind === "decision") return eventsOf(record, "quote").length > 0;
    if (kind === "allocate") return eventsOf(record, "receipt").length > 0 && eventsOf(record, "certificate").length > 0;
    return true;
  });
}

export function formatDecimal(value: string) {
  const [integer, fraction] = value.split(".");
  const whole = integer.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return fraction === undefined ? whole : whole + "." + fraction;
}

const utcDate = new Intl.DateTimeFormat("en-GB", { dateStyle: "medium", timeStyle: "short", timeZone: "UTC" });

export function formatDate(value: string) {
  return utcDate.format(new Date(value)) + " UTC";
}

export function actionData(kind: ActionKind, form: FormData): Record<string, unknown> {
  const data: Record<string, unknown> = {};
  for (const [name, value] of form) {
    if (typeof value === "string" && value.trim()) data[name] = value;
  }
  if (kind === "quote") {
    const amounts = form.getAll("amount");
    data.lines = form.getAll("description").map((description, index) => ({
      description, amount: amounts[index],
    }));
    delete data.description;
    delete data.amount;
  }
  if (kind === "decision") {
    const choices = form.getAll("disposition");
    data.lines = form.getAll("accepted").map((accepted, index) => ({
      line: index + 1, accepted, disposition: choices[index],
    }));
    delete data.accepted;
    delete data.disposition;
  }
  if (data.instruction === "__none__") delete data.instruction;
  if (data.application === "__none__") delete data.application;
  if (kind === "work") data.completed = data.completed === "true";
  if (typeof data.due_at === "string") data.due_at = new Date(data.due_at).toISOString();
  return data;
}

export type Operation = { payload: string; id: string };

export function retryOperation(previous: Operation | null, value: unknown): Operation {
  const payload = JSON.stringify(value);
  return previous?.payload === payload ? previous : { payload, id: crypto.randomUUID() };
}
