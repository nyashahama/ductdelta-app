import { useId, useRef, useState, type FormEvent } from "react";
import { api, reportError, requestJson } from "../../lib/api";
import {
  actionData, actions, availableActions, dispositions, eventsOf, eventTitle, formatDecimal,
  outcomes, retryOperation, unreversedAllocations, type ActionKind, type CaseEvent, type CaseRecord, type Operation,
} from "./case-data";
import { useActiveComponent } from "./use-case-resource";
import styles from "./cases.module.css";

type Option = readonly [string, string];
type FieldProps = {
  name: string;
  label: string;
  optional?: boolean;
  input?: "text" | "textarea" | "money" | "datetime-local";
  options?: readonly Option[];
  value?: string;
  limit?: number;
  readOnly?: boolean;
};

const amountPattern = "-?(0|[1-9][0-9]{0,11})([.][0-9]{1,2})?";

function Field({ name, label, optional, input = "text", options, value, limit, readOnly }: FieldProps) {
  const id = useId();
  const base = { id, name, required: !optional, defaultValue: value, readOnly };
  return (
    <div className="form-field">
      <label htmlFor={id}>{label}{optional && <span className={styles.optional}> optional</span>}</label>
      {options ? (
        <select {...base}>
          <option value="">{optional ? "None" : "Choose " + label.toLowerCase()}</option>
          {options.map(([key, text]) => <option value={key} key={key}>{text}</option>)}
        </select>
      ) : input === "textarea" ? (
        <textarea {...base} rows={4} maxLength={limit} />
      ) : (
        <input {...base} type={input === "money" ? "text" : input}
          maxLength={input === "money" ? 16 : limit}
          pattern={input === "money" ? amountPattern : undefined}
          title={input === "money" ? "Use up to twelve whole digits and two decimal places, without commas." : undefined} />
      )}
    </div>
  );
}

function ReferenceField({ label }: { label: string }) {
  return <Field name="reference" label={label} limit={160} />;
}

function EventField({ events, ...field }: FieldProps & { events: CaseEvent[] }) {
  const options = [...events].reverse().map((event): Option => [event.id, eventTitle(event)]);
  return <Field {...field} options={options} />;
}

function AgreementField({ record }: { record: CaseRecord }) {
  return <Field name="agreement" label="Agreement reference" value={record.agreement ?? undefined}
    readOnly={Boolean(record.agreement)} limit={160} />;
}

function QuoteFields() {
  const [rows, setRows] = useState([1]);
  const nextRow = useRef(2);

  return (
    <>
      <ReferenceField label="Quote reference" />
      <p className={styles.help}>Enter credits as negative amounts. Use a decimal point and omit commas.</p>
      {rows.map((row, index) => (
        <fieldset key={row} className={styles.editLine}>
          <legend>Line {index + 1}</legend>
          <Field name="description" label={`Description for line ${index + 1}`} limit={2000} />
          <Field name="amount" label={`Amount for line ${index + 1}`} input="money" />
          {rows.length > 1 && <button className="button secondary" type="button"
            aria-label={`Remove quote line ${index + 1}`}
            onClick={() => setRows(rows.filter((id) => id !== row))}>Remove line</button>}
        </fieldset>
      ))}
      <button type="button" className="button secondary" disabled={rows.length === 99}
        onClick={() => { const row = nextRow.current++; setRows([...rows, row]); }}>Add quote line</button>
    </>
  );
}

function DecisionFields({ record }: { record: CaseRecord }) {
  const latest = eventsOf(record, "quote").at(-1);
  if (!latest) return null;
  const previous = eventsOf(record, "decision").reverse().find((event) => event.data.quote === latest.id);
  return (
    <>
      <EventField name="quote" label="Quote" events={[latest]} value={latest.id} />
      {latest.data.lines.map((line, index) => {
        const number = index + 1;
        const saved = previous?.data.lines.find((entry) => entry.line === number);
        return (
          <fieldset key={number} className={styles.editLine}>
            <legend>Line {number}</legend>
            <p>{line.description}</p>
            <p className={styles.help}>Proposed {formatDecimal(line.amount)}</p>
            <Field name="accepted" label={`Accepted amount for line ${number}`} input="money" value={saved?.accepted ?? "0"} />
            <Field name="disposition" label={`Disposition for line ${number}`} options={dispositions} value={saved?.disposition ?? "open"} />
          </fieldset>
        );
      })}
      <Field name="reason" label="Decision reason" input="textarea" limit={4000} />
    </>
  );
}

function CertificateFields({ record }: { record: CaseRecord }) {
  const latest = eventsOf(record, "certificate").at(-1);
  return (
    <>
      <ReferenceField label="Certificate reference" />
      {latest && <EventField name="predecessor" label="Previous certificate" events={[latest]} value={latest.id} />}
      <EventField name="application" label="Payment application" optional events={eventsOf(record, "application")} />
      <Field name="cumulative" label="Cumulative certified amount" input="money" />
      <Field name="withheld" label="Retention withheld this period" input="money" value="0" />
      <Field name="released" label="Retention released this period" input="money" value="0" />
      <Field name="reason" label="Reason" input="textarea" limit={4000} optional />
    </>
  );
}

function ActionFields({ kind, record }: { kind: ActionKind; record: CaseRecord }) {
  switch (kind) {
    case "notice":
      return <>
        <ReferenceField label="Notice reference" />
        <AgreementField record={record} />
        <Field name="body" label="Notice text" input="textarea" limit={12000} />
        <Field name="due_at" label="Due date and time" input="datetime-local" optional />
        <p className={styles.help}>Uses the time zone on this device.</p>
      </>;
    case "notice_dispatch":
    case "notice_receipt": {
      const dispatched = new Set(eventsOf(record, "notice_dispatch").map((event) => event.data.notice));
      const notices = eventsOf(record, "notice").filter((event) => kind === "notice_dispatch" || dispatched.has(event.id));
      return <>
        <EventField name="notice" label="Notice" events={notices} />
        <ReferenceField label={kind === "notice_dispatch" ? "Dispatch reference" : "Acknowledgement reference"} />
      </>;
    }
    case "instruction":
      return <>
        <ReferenceField label="Instruction reference" />
        <AgreementField record={record} />
        <Field name="scope" label="Authorized scope" input="textarea" limit={8000} />
      </>;
    case "work":
      return <>
        <Field name="description" label="Work performed" input="textarea" limit={8000} />
        <EventField name="instruction" label="Instruction" events={eventsOf(record, "instruction")} optional />
        <Field name="completed" label="Work status" options={[["false", "In progress"], ["true", "Complete"]]} />
      </>;
    case "quote": return <QuoteFields />;
    case "decision": return <DecisionFields record={record} />;
    case "application":
      return <>
        <ReferenceField label="Application reference" />
        <Field name="amount" label="Applied amount" input="money" />
      </>;
    case "certificate": return <CertificateFields record={record} />;
    case "receipt":
      return <>
        <ReferenceField label="Receipt reference" />
        <Field name="amount" label="Receipt amount" input="money" />
      </>;
    case "allocate":
      return <>
        <EventField name="receipt" label="Cash receipt" events={eventsOf(record, "receipt")} />
        <EventField name="certificate" label="Certificate" events={eventsOf(record, "certificate")} />
        <Field name="amount" label="Allocation amount" input="money" />
        <ReferenceField label="Allocation reference" />
      </>;
    case "reverse_allocation":
      return <>
        <EventField name="allocation" label="Allocation" events={unreversedAllocations(record)} />
        <Field name="reason" label="Reversal reason" input="textarea" limit={4000} />
      </>;
    case "close":
      return <>
        <Field name="outcome" label="Outcome" options={outcomes} />
        <Field name="reason" label="Closeout reason" input="textarea" limit={4000} />
      </>;
  }
}

type Props = {
  record: CaseRecord;
  permission: "read" | "capture";
  path: string;
  expire(): void;
  onSaved(): void;
};

export default function CaseActions({ record, permission, path, expire, onSaved }: Props) {
  const [kind, setKind] = useState<ActionKind | "">("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const operation = useRef<Operation | null>(null);
  const pending = useRef(false);
  const mounted = useActiveComponent();
  const selectionId = useId();
  const headingId = useId();
  const available = availableActions(record, permission);
  const selected = kind && available.includes(kind) ? kind : "";

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!selected || pending.current) return;
    const form = new FormData(event.currentTarget);
    pending.current = true;
    setBusy(true);
    setError("");
    try {
      const data = actionData(selected, form);
      operation.current = retryOperation(operation.current, { kind: selected, data });
      await api(path + "/actions", requestJson({ operation_id: operation.current.id, kind: selected, data }));
      if (!mounted.current) return;
      operation.current = null;
      setKind("");
      onSaved();
    } catch (problem) {
      if (mounted.current) setError(reportError(problem, expire));
    } finally {
      pending.current = false;
      if (mounted.current) setBusy(false);
    }
  }

  if (available.length === 0) return null;
  return (
    <section className={`panel ${styles.section}`} aria-labelledby={headingId}>
      <h3 className={styles.panelHeading} id={headingId}>Record an action</h3>
      <div className={styles.panelBody}>
        <div className="form-field">
          <label htmlFor={selectionId}>Action</label>
          <select id={selectionId} value={selected} disabled={busy} onChange={(event) => {
            operation.current = null;
            setError("");
            setKind(event.target.value as ActionKind | "");
          }}>
            <option value="">Choose an action</option>
            {available.map((action) => <option key={action} value={action}>{actions[action].label}</option>)}
          </select>
        </div>
        {selected && (
          <form onSubmit={save} key={selected} className={styles.actionForm} aria-label={actions[selected].label}>
            <fieldset disabled={busy} className={styles.formFields}>
              <ActionFields kind={selected} record={record} />
            </fieldset>
            {error && <p className="error" role="alert">{error}</p>}
            <button type="submit" className="button primary" disabled={busy}>{busy ? "Recording…" : "Record action"}</button>
          </form>
        )}
      </div>
    </section>
  );
}
