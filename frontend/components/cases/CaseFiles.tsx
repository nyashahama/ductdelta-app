import { useId, useRef, useState, type FormEvent } from "react";
import { api, reportError } from "../../lib/api";
import { formatDate, retryOperation, type CaseRecord, type Operation } from "./case-data";
import { useActiveComponent, useCaseResource } from "./use-case-resource";
import styles from "./cases.module.css";

type CaseFile = {
  id: string;
  filename: string;
  media_type: string;
  caption: string | null;
  access_class: "site" | "finance";
  byte_size: number;
  recorded_at: string;
};

const mediaByExtension: Partial<Record<string, string>> = {
  pdf: "application/pdf", png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", txt: "text/plain",
};
const mediaLabels = new Map([
  ["application/pdf", "PDF"], ["image/png", "PNG"], ["image/jpeg", "JPEG"], ["text/plain", "Text file"],
]);
const size = new Intl.NumberFormat("en-GB", { maximumFractionDigits: 1 });

function fileSize(bytes: number) {
  if (bytes < 1024) return bytes + (bytes === 1 ? " byte" : " bytes");
  if (bytes < 1024 * 1024) return size.format(bytes / 1024) + " KiB";
  return size.format(bytes / (1024 * 1024)) + " MiB";
}

function FileUpload({ finance, path, expire, onUploaded }: {
  finance: boolean; path: string; expire(): void; onUploaded(file: string): void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const details = useRef<HTMLDetailsElement>(null);
  const picker = useRef<HTMLInputElement>(null);
  const selection = useRef<File | null>(null);
  const operation = useRef<Operation | null>(null);
  const pending = useRef(false);
  const mounted = useActiveComponent();
  const ids = useId();

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (pending.current) return;
    const form = event.currentTarget;
    const values = new FormData(form);
    const file = picker.current?.files?.[0];
    if (!file) return;
    const extension = file.name.match(/\.([^.]+)$/)?.[1].toLowerCase();
    const media = file.type.toLowerCase() || (extension ? mediaByExtension[extension] : "");
    const access = values.get("access") === "finance" && finance ? "finance" : "site";
    const caption = String(values.get("caption") || "").trim();
    let invalid = "";
    if (file.size === 0) invalid = "Choose a file that is not empty.";
    else if (file.size > 5 * 1024 * 1024) invalid = "Choose a file up to 5 MiB.";
    else if (!media || !mediaLabels.has(media)) invalid = "Choose a PDF, PNG, JPEG or TXT file.";
    if (invalid || !media) {
      setError(invalid);
      picker.current?.focus();
      return;
    }

    if (selection.current !== file) {
      selection.current = file;
      operation.current = null;
    }
    operation.current = retryOperation(operation.current, { caption, access });
    pending.current = true;
    setBusy(true);
    setError("");

    try {
      const headers = new Headers({
        "Content-Type": media,
        "X-Operation-Id": operation.current.id,
        "X-File-Name": encodeURIComponent(file.name),
        "X-File-Access": access,
      });
      if (caption) headers.set("X-File-Caption", encodeURIComponent(caption));
      await api(path, { method: "POST", headers, body: file });
      if (!mounted.current) return;
      operation.current = null;
      selection.current = null;
      form.reset();
      if (details.current) details.current.open = false;
      details.current?.querySelector<HTMLElement>("summary")?.focus();
      onUploaded(file.name);
    } catch (problem) {
      if (mounted.current) setError(reportError(problem, expire));
    } finally {
      pending.current = false;
      if (mounted.current) setBusy(false);
    }
  }

  return (
    <details ref={details} className={styles.upload}>
      <summary>Add a file</summary>
      <form className={styles.actionForm} onSubmit={submit}>
        <fieldset className={styles.formFields} disabled={busy}>
          <div className="form-field">
            <label htmlFor={ids + "file"}>Original file</label>
            <input id={ids + "file"} ref={picker} type="file" required aria-describedby={ids + "help"}
              accept=".pdf,.png,.jpg,.jpeg,.txt,application/pdf,image/png,image/jpeg,text/plain" />
            <p className={styles.help} id={ids + "help"}>PDF, PNG, JPEG or TXT. Maximum 5 MiB.</p>
          </div>
          <div className={styles.uploadFields}>
            <div className="form-field">
              <label htmlFor={ids + "caption"}>Caption <span className={styles.optional}>optional</span></label>
              <input id={ids + "caption"} name="caption" />
            </div>
            <div className="form-field">
              <label htmlFor={ids + "access"}>File visibility</label>
              <select id={ids + "access"} name="access">
                <option value="site">Site team</option>
                {finance && <option value="finance">Finance only</option>}
              </select>
            </div>
          </div>
        </fieldset>
        {error && <p className="error" role="alert">{error}</p>}
        <button type="submit" className="button primary" disabled={busy}>{busy ? "Uploading…" : "Upload file"}</button>
      </form>
    </details>
  );
}

export default function CaseFiles({ path, permission, record, expire, onChanged }: {
  path: string; permission: "read" | "capture"; record: CaseRecord; expire(): void; onChanged(): void;
}) {
  const filePath = path + "/files";
  const { resource, reload } = useCaseResource<CaseFile[]>(filePath, expire);
  const [confirmation, setConfirmation] = useState("");
  const heading = useId();

  return (
    <section className={`panel ${styles.section}`} aria-labelledby={heading}>
      <h3 className={styles.panelHeading} id={heading}>Original case files</h3>
      {resource.kind === "loading" && <p className={styles.notice} role="status">Loading files…</p>}
      {resource.kind === "error" && (
        <div className={styles.panelBody}>
          <p className="error" role="alert">{resource.message}</p>
          <button type="button" className="button secondary" onClick={reload}>Reload files</button>
        </div>
      )}
      {resource.kind === "ready" && (resource.data.length === 0
        ? <p className={styles.notice}>No original files have been added.</p>
        : <ul className={styles.files}>
          {resource.data.map((file) => (
            <li key={file.id}>
              <div>
                <p className={styles.fileName}>{file.filename}</p>
                <p className={styles.fileMeta}>
                  <span className="badge">{file.access_class === "finance" ? "Finance" : "Site"}</span>
                  <span>{mediaLabels.get(file.media_type) || file.media_type}</span>
                  <span>{fileSize(file.byte_size)}</span>
                  <time dateTime={file.recorded_at}>{formatDate(file.recorded_at)}</time>
                </p>
                {file.caption && <p className={styles.caption}>{file.caption}</p>}
              </div>
              <a className="button secondary" href={filePath + "/" + encodeURIComponent(file.id)}
                aria-label={`Download ${file.filename}`}>Download</a>
            </li>
          ))}
        </ul>)}
      {!record.closed && permission === "capture" && (
        <FileUpload finance={record.capabilities.includes("finance")} path={filePath} expire={expire} onUploaded={(name) => {
          setConfirmation(name + " uploaded.");
          reload();
          onChanged();
        }} />
      )}
      {confirmation && <p className={styles.confirmation} role="status">{confirmation}</p>}
    </section>
  );
}
