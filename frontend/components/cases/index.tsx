import { useCallback, useEffect, useId, useRef, useState, type FormEvent } from "react";
import { api, reportError, requestJson, type Project } from "../../lib/api";
import CaseActions from "./CaseActions";
import { EvidenceTimeline, FinancialSummary } from "./CaseEvidence";
import CaseFiles from "./CaseFiles";
import { casePath, retryOperation, type CasePage, type CaseRecord, type CaseSummary, type Operation } from "./case-data";
import { useActiveComponent, useCaseResource } from "./use-case-resource";
import styles from "./cases.module.css";

export type CasesWorkspaceProps = {
  project: Project;
  selectedCaseId: string | null;
  sourceObservationId: string | null;
  onSelectCase(id: string): void;
  onOpenObservation(id: string): void;
  onChanged(): void;
  onSessionExpired(): void;
};

function CaseStatus({ closed }: { closed: boolean }) {
  return <span className={`badge ${closed ? styles.closed : styles.open}`}>{closed ? "Closed" : "Open"}</span>;
}

type RegisterProps = {
  cases: CaseSummary[];
  selected: string | null;
  onSelect(id: string): void;
  ready: boolean;
  hasMore: boolean;
  loadMore(): void;
  error: string;
  retry(): void;
};

function CaseRegister({ cases, selected, onSelect, ready, hasMore, loadMore, error, retry }: RegisterProps) {
  const title = useId();
  return (
    <section className={`panel ${styles.register}`} aria-labelledby={title}>
      <header className={styles.panelBar}>
        <h2 id={title}>Case register</h2>
        {cases.length > 0 && <span className="badge">{cases.length} {hasMore ? "loaded" : cases.length === 1 ? "case" : "cases"}</span>}
      </header>
      {cases.length > 0 && (
        <ul className={styles.caseList}>
          {cases.map((item) => (
            <li key={item.id}>
              <button type="button" aria-label={item.title} aria-pressed={item.id === selected} onClick={() => onSelect(item.id)}>
                <span>{item.title}</span><CaseStatus closed={item.closed} />
              </button>
            </li>
          ))}
        </ul>
      )}
      {!ready && !error && <p className={styles.notice} role="status">Loading change cases…</p>}
      {ready && cases.length === 0 && <p className={styles.notice}>No change cases have been recorded for this project.</p>}
      {error && <div className={styles.panelBody}>
        <p className="error" role="alert">{error}</p>
        <button type="button" className="button secondary" onClick={retry}>Reload case register</button>
      </div>}
      {hasMore && <div className={styles.panelBody}>
        <button type="button" className="button secondary" onClick={loadMore}>Load earlier cases</button>
      </div>}
    </section>
  );
}

function CreateCaseDialog({ project, sourceId, expire, onDismiss, onCreated }: {
  project: Project; sourceId: string | null; expire(): void; onDismiss(): void; onCreated(id: string): void;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const operation = useRef<Operation | null>(null);
  const pending = useRef(false);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const ids = useId();
  const mounted = useActiveComponent();

  useEffect(() => {
    const popup = dialog.current;
    popup?.showModal();
    return () => popup?.close();
  }, []);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (pending.current) return;
    const title = String(new FormData(event.currentTarget).get("title") ?? "").trim();
    if (!title) {
      setError("Enter a case title.");
      return;
    }
    const body = sourceId ? { title, observation_id: sourceId } : { title };
    operation.current = retryOperation(operation.current, body);
    pending.current = true;
    setBusy(true);
    setError("");
    try {
      const saved = await api<{ id: string }>(casePath(project.id), requestJson({ operation_id: operation.current.id, ...body }));
      if (mounted.current) onCreated(saved.id);
    } catch (problem) {
      if (mounted.current) setError(reportError(problem, expire));
    } finally {
      pending.current = false;
      if (mounted.current) setBusy(false);
    }
  }

  return (
    <dialog className={styles.dialog} ref={dialog} aria-labelledby={ids + "dialog"} onCancel={(event) => {
      event.preventDefault();
      if (!pending.current) onDismiss();
    }}>
      <div className={styles.panelBody}>
        <div>
          <h2 id={ids + "dialog"}>New change case</h2>
          <p className="muted">{project.name}{sourceId && " · Linked to this observation"}</p>
        </div>
        <form onSubmit={submit} className={styles.actionForm}>
          <div className="form-field">
            <label htmlFor={ids + "title"}>Case title</label>
            <input id={ids + "title"} name="title" required maxLength={160} readOnly={busy} autoFocus />
          </div>
          {error && <p className="error" role="alert">{error}</p>}
          <div className={styles.dialogActions}>
            <button type="button" disabled={busy} className="button secondary" onClick={onDismiss}>Cancel</button>
            <button type="submit" disabled={busy} className="button primary">{busy ? "Creating…" : "Create case"}</button>
          </div>
        </form>
      </div>
    </dialog>
  );
}

function CaseRecordPanel({ project, id, onOpenObservation, onChanged, onSessionExpired, onStatus }: {
  project: Project; id: string; onOpenObservation(id: string): void; onChanged(): void;
  onSessionExpired(): void; onStatus(id: string, closed: boolean): void;
}) {
  const path = casePath(project.id, id);
  const { resource, reload } = useCaseResource<CaseRecord>(path, onSessionExpired);
  const record = resource.kind === "ready" ? resource.data : null;
  const [confirmation, setConfirmation] = useState("");
  const heading = useRef<HTMLHeadingElement>(null);
  const focused = useRef(false);
  const closed = record?.closed;

  useEffect(() => {
    if (closed === undefined) return;
    onStatus(id, closed);
    if (!focused.current) {
      heading.current?.focus();
      focused.current = true;
    }
  }, [id, closed, onStatus]);

  if (resource.kind === "loading") return <p className={`panel ${styles.notice}`} role="status">Loading case record…</p>;
  if (resource.kind === "error") return (
    <div className={`panel ${styles.panelBody}`}>
      <p className="error" role="alert">{resource.message}</p>
      <button type="button" className="button secondary" onClick={reload}>Reload case record</button>
    </div>
  );

  const current = resource.data;
  const observation = current.observation_id;
  return (
    <div className={styles.detail}>
      <section className={`panel ${styles.cover}`} aria-label="Case summary">
        <div><h2 ref={heading} tabIndex={-1}>{current.title}</h2><CaseStatus closed={current.closed} /></div>
        <dl>
          <div><dt>Agreement</dt><dd>{current.agreement ?? "Not recorded"}</dd></div>
          <div><dt>Case ID</dt><dd>{current.id}</dd></div>
        </dl>
        {observation && <button type="button" className="button secondary" onClick={() => onOpenObservation(observation)}>Open source observation</button>}
      </section>
      {confirmation && <p className={styles.confirmation} role="status">{confirmation}</p>}
      {current.financial && <FinancialSummary value={current.financial} />}
      <CaseFiles key={current.capabilities.join("|")} path={path} permission={project.permission}
        record={current} expire={onSessionExpired} onChanged={onChanged} />
      <div className={styles.eventsColumns}>
        <CaseActions path={path} permission={project.permission} record={current} expire={onSessionExpired} onSaved={() => {
          setConfirmation("Action recorded.");
          reload();
          onChanged();
        }} />
        <EvidenceTimeline events={current.events} />
      </div>
    </div>
  );
}

export default function CasesWorkspace({
  project, selectedCaseId, sourceObservationId, onSelectCase, onOpenObservation, onChanged, onSessionExpired,
}: CasesWorkspaceProps) {
  const [cursor, setCursor] = useState<string | null>(null);
  const [previous, setPrevious] = useState<CaseSummary[]>([]);
  const [statuses, setStatuses] = useState<Record<string, boolean>>({});
  const [newCase, setNewCase] = useState(false);
  const [dismissedSource, setDismissedSource] = useState<string | null>(null);
  const firstPath = casePath(project.id);
  const path = cursor ? firstPath + "?before=" + encodeURIComponent(cursor) : firstPath;
  const { resource, reload } = useCaseResource<CasePage>(path, onSessionExpired);
  const ready = resource.kind === "ready";
  const received = ready ? resource.data.cases : [];
  const next = ready ? resource.data.next_before : null;
  const items = [...previous, ...received].map((item) => ({ ...item, closed: statuses[item.id] ?? item.closed }));
  const canCreate = project.permission === "capture";
  const linkedSource = sourceObservationId && sourceObservationId !== dismissedSource ? sourceObservationId : null;
  const workspaceTitle = useId();

  const setStatus = useCallback((id: string, closed: boolean) => {
    setStatuses((current) => current[id] === closed ? current : { ...current, [id]: closed });
  }, []);

  function dismissCreate() {
    setNewCase(false);
    if (linkedSource) setDismissedSource(linkedSource);
  }

  return (
    <section className={styles.workspace} aria-labelledby={workspaceTitle}>
      <header className={styles.heading}>
        <div>
          <h1 id={workspaceTitle}>Change cases</h1>
          <p className="muted">Track changes from instruction through payment.</p>
        </div>
        {canCreate && <button type="button" className="button primary" onClick={() => setNewCase(true)}>New case</button>}
      </header>
      <div className={styles.workspaceGrid}>
        <CaseRegister cases={items} selected={selectedCaseId} onSelect={onSelectCase} ready={ready}
          error={resource.kind === "error" ? resource.message : ""} retry={reload} hasMore={Boolean(next)} loadMore={() => {
            if (!next) return;
            setPrevious(items);
            setCursor(next);
          }} />
        {selectedCaseId
          ? <CaseRecordPanel key={selectedCaseId} project={project} id={selectedCaseId} onOpenObservation={onOpenObservation}
            onChanged={onChanged} onSessionExpired={onSessionExpired} onStatus={setStatus} />
          : <p className={`panel ${styles.notice}`}>Select a case to open its record.</p>}
      </div>
      {canCreate && (newCase || linkedSource) && <CreateCaseDialog key={linkedSource ?? "new"} project={project}
        sourceId={linkedSource} expire={onSessionExpired} onDismiss={dismissCreate} onCreated={(id) => {
          dismissCreate();
          setPrevious([]);
          setCursor(null);
          reload();
          onSelectCase(id);
          onChanged();
        }} />}
    </section>
  );
}
