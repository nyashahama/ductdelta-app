import { useId } from "react";
import {
  dispositions, eventTitle, formatDate, formatDecimal, moneyLabels, outcomes, type CaseEvent, type FinancialPosition,
} from "./case-data";
import styles from "./cases.module.css";

const referenceKeys = new Set(["notice", "instruction", "quote", "predecessor", "application", "receipt", "certificate", "allocation"]);
const amountKeys = new Set(["amount", "cumulative", "withheld", "released"]);
const eventLabels = {
  reference: "Reference", agreement: "Agreement", scope: "Authorized scope", body: "Notice text", due_at: "Due",
  notice: "Notice", instruction: "Instruction", description: "Work performed", completed: "Completion",
  quote: "Quote", reason: "Reason", amount: "Amount", cumulative: "Cumulative certified",
  withheld: "Retention withheld", released: "Retention released", predecessor: "Earlier certificate",
  application: "Payment application", receipt: "Cash receipt", certificate: "Certificate", allocation: "Allocation", outcome: "Outcome",
};

export function FinancialSummary({ value }: { value: FinancialPosition }) {
  const heading = useId();
  return (
    <section className={`panel ${styles.section}`} aria-labelledby={heading}>
      <div className={styles.panelBar}>
        <h3 id={heading}>Financial position</h3>
        <span className="badge">{value.currency}{value.basis === "excl_vat" && " · Excl. VAT"}</span>
      </div>
      {value.quote_awaiting_decision && <p className={styles.notice}>The latest quote is awaiting a decision.</p>}
      <dl className={styles.financial}>
        {(Object.entries(moneyLabels) as [keyof typeof moneyLabels, string][]).map(([key, label]) => {
          const amount = value[key];
          if (key === "unallocated" && amount == null) return null;
          return (
            <div key={key} className={key === "outstanding" ? styles.outstanding : undefined}>
              <dt>{label}</dt>
              <dd className={amount == null ? styles.unrecorded : undefined}>
                {amount == null ? "Not recorded" : formatDecimal(amount)}
              </dd>
            </div>
          );
        })}
      </dl>
    </section>
  );
}

function EventLines({ event }: { event: Extract<CaseEvent, { kind: "quote" | "decision" }> }) {
  return (
    <div className={styles.eventTable}>
      {event.kind === "quote" ? (
        <table aria-label="Quoted lines">
          <thead><tr><th scope="col">Description</th><th scope="col">Amount</th></tr></thead>
          <tbody>{event.data.lines.map((line, index) => (
            <tr key={index}><td>{line.description}</td><td>{formatDecimal(line.amount)}</td></tr>
          ))}</tbody>
        </table>
      ) : (
        <table aria-label="Decision by line">
          <thead><tr><th scope="col">Line</th><th scope="col">Accepted</th><th scope="col">Disposition</th></tr></thead>
          <tbody>{event.data.lines.map((line) => (
            <tr key={line.line}>
              <td>{line.line}</td><td>{formatDecimal(line.accepted)}</td>
              <td>{dispositions.find(([key]) => key === line.disposition)?.[1] ?? line.disposition}</td>
            </tr>
          ))}</tbody>
        </table>
      )}
    </div>
  );
}

function eventValue(key: string, value: unknown, references: Map<string, string>) {
  const text = String(value);
  if (referenceKeys.has(key)) return references.get(text) ?? text;
  if (amountKeys.has(key)) return formatDecimal(text);
  if (key === "completed") return value === true ? "Complete" : "In progress";
  if (key === "due_at") return formatDate(text);
  if (key === "outcome") return outcomes.find(([candidate]) => candidate === value)?.[1] ?? text;
  return text;
}

export function EvidenceTimeline({ events }: { events: CaseEvent[] }) {
  const heading = useId();
  const references = new Map(events.map((event) => [event.id, eventTitle(event)]));
  return (
    <section className={`panel ${styles.section}`} aria-labelledby={heading}>
      <h3 className={styles.panelHeading} id={heading}>Evidence timeline</h3>
      {events.length === 0
        ? <p className={styles.notice}>No actions have been recorded for this case.</p>
        : <ol className={styles.timeline}>{events.map((event) => {
          const data: Record<string, unknown> = event.data;
          const snapshot = event.data.financial_snapshot;
          return (
            <li key={event.id}>
              <details>
                <summary>
                  <span>{eventTitle(event)}</span>
                  <time dateTime={event.recorded_at}>{formatDate(event.recorded_at)}</time>
                </summary>
                <dl className={styles.eventFields}>
                  {Object.entries(eventLabels).map(([key, label]) => data[key] != null && (
                    <div key={key}><dt>{label}</dt><dd>{eventValue(key, data[key], references)}</dd></div>
                  ))}
                  {snapshot && Object.entries(snapshot).map(([key, value]) => {
                    const label = key === "work_delta" ? "Certified this period" : moneyLabels[key as keyof typeof moneyLabels];
                    return label && value != null && <div key={`snapshot-${key}`}><dt>{label}</dt><dd>{formatDecimal(value)}</dd></div>;
                  })}
                </dl>
                {(event.kind === "quote" || event.kind === "decision") && <EventLines event={event} />}
                <p className={styles.help}>Recorded by {event.actor_id}</p>
              </details>
            </li>
          );
        })}</ol>}
    </section>
  );
}
