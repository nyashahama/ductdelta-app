"use strict";

const element = (id) => document.getElementById(id);
const projectPicker = element("project");
const signInForm = element("sign-in-form");
const captureDialog = element("capture-dialog");
const captureForm = element("capture-form");
const newObservation = element("new-observation");
const loadMore = element("load-more");
const retryLog = element("retry-log");
const retryProjects = element("retry-projects");
const rowList = element("observation-rows");
const dateShort = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeZone: "UTC" });
const dateFull = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short", timeZone: "UTC" });

let workspace = null;
let active = null;
let draft = null;

function message(id, value) {
  const region = element(id);
  region.textContent = value;
  region.hidden = !value;
}

async function request(path, { method = "GET", body } = {}) {
  const response = await fetch(path, {
    method,
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (response.status === 204) return null;
  const data = await response.json().catch(() => null);
  if (response.ok) return data;
  const error = new Error(data?.message || "The request failed. Try again.");
  error.status = response.status;
  throw error;
}

function errorText(error) {
  return error.status ? error.message : "Could not reach DuctDelta. Try again.";
}

function projectError(error, region) {
  if (error.status === 401) {
    if (!workspace?.signingOut) showSignIn("Your session ended. Sign in again.");
  } else {
    message(region, errorText(error));
  }
}

function observationPath(scope) {
  return "/api/projects/" + encodeURIComponent(scope.project.id) + "/observations";
}

function resetDetail() {
  element("detail-body").hidden = true;
  element("detail-tag").hidden = true;
  for (const id of ["note", "location", "observed", "recorded", "actor", "id"]) {
    element("detail-" + id).textContent = "";
  }
  message("detail-error", "");
  message("detail-status", "Select an observation to open its full record.");
}

function chooseProject(project) {
  if (captureDialog.open) closeCapture();
  active = project ? { project, next: null, listRequest: null, detailRequest: null } : null;
  element("workspace-project").textContent = project?.name || "Assigned projects";
  newObservation.hidden = project?.permission !== "capture";
  rowList.replaceChildren();
  element("queue-table").hidden = true;
  element("queue-count").hidden = true;
  updateLogActions(false, false);
  message("log-error", "");
  message("log-status", project ? "Loading observations…" : "No project selected.");
  message("save-status", "");
  resetDetail();
  document.dispatchEvent(new CustomEvent("ductdelta:project-changed", { detail: { project } }));
  if (active) void loadObservations(active);
}

function showSignIn(error = "") {
  workspace = null;
  element("workspace").hidden = true;
  chooseProject(null);
  projectPicker.replaceChildren();
  element("account-name").textContent = "";
  message("workspace-error", "");
  element("startup").hidden = true;
  element("sign-in").hidden = false;
  signInForm.reset();
  message("sign-in-error", error);
  element("access-key").focus();
}

function showWorkspace(session) {
  workspace = { projects: [], signingOut: false };
  element("startup").hidden = true;
  element("sign-in").hidden = true;
  element("workspace").hidden = false;
  element("account-name").textContent = session.name;
  element("workspace-content").focus();
  void loadProjects(workspace);
}

async function loadProjects(session) {
  projectPicker.disabled = true;
  projectPicker.replaceChildren(new Option("Loading projects…", ""));
  retryProjects.hidden = true;
  message("workspace-error", "");
  try {
    const projects = await request("/api/projects");
    if (workspace !== session) return;
    session.projects = projects;
    if (projects.length === 0) {
      projectPicker.replaceChildren(new Option("No assigned projects", ""));
      chooseProject(null);
      message("log-status", "Your account has no assigned projects.");
      return;
    }
    projectPicker.replaceChildren(...projects.map((project) => new Option(project.name, project.id)));
    projectPicker.disabled = false;
    chooseProject(projects[0]);
  } catch (error) {
    if (workspace !== session) return;
    projectPicker.replaceChildren(new Option("Projects unavailable", ""));
    chooseProject(null);
    projectError(error, "workspace-error");
    retryProjects.hidden = !workspace;
  }
}

function updateLogActions(more, retry, busy = false) {
  loadMore.hidden = !more;
  loadMore.disabled = busy;
  retryLog.hidden = !retry;
  element("log-footer").hidden = !more && !retry;
}

function listRow(scope, observation) {
  const row = rowList.insertRow();
  const summary = row.insertCell();
  const button = document.createElement("button");
  button.type = "button";
  button.className = "row-choice";
  button.dataset.id = observation.id;
  button.textContent = observation.note_preview || "Open observation";
  button.setAttribute("aria-pressed", String(scope.detailRequest?.id === observation.id));
  button.addEventListener("click", () => void openObservation(scope, observation.id));
  summary.append(button);
  if (observation.location) {
    const location = document.createElement("span");
    location.className = "row-location";
    location.textContent = observation.location;
    summary.append(location);
  }
  const date = document.createElement("time");
  date.dateTime = observation.recorded_at;
  date.textContent = dateShort.format(new Date(observation.recorded_at));
  row.insertCell().append(date);
}

async function loadObservations(scope, before = null) {
  if (active !== scope) return;
  const revision = {};
  scope.listRequest = revision;
  message("log-error", "");
  updateLogActions(Boolean(before), false, true);
  const query = before ? "?before=" + encodeURIComponent(before) : "";
  try {
    const page = await request(observationPath(scope) + query);
    if (active !== scope || scope.listRequest !== revision) return;
    if (!before) rowList.replaceChildren();
    for (const observation of page.observations) listRow(scope, observation);
    const count = rowList.rows.length;
    const countBadge = element("queue-count");
    countBadge.textContent = count + (page.next ? " loaded" : count === 1 ? " record" : " records");
    countBadge.hidden = count === 0;
    element("queue-table").hidden = count === 0;
    message("log-status", count ? "" : "No observations have been recorded for this project.");
    scope.next = page.next;
    updateLogActions(Boolean(page.next), false);
    if (before) {
      const newRow = [...rowList.rows].find((row) => row.querySelector("button").dataset.id === page.observations[0]?.id);
      newRow?.querySelector("button").focus();
    }
  } catch (error) {
    if (active !== scope || scope.listRequest !== revision) return;
    message("log-status", "");
    projectError(error, "log-error");
    if (active === scope) updateLogActions(Boolean(before), !before);
  }
}

async function openObservation(scope, id) {
  if (active !== scope) return;
  const detailRequest = { id };
  scope.detailRequest = detailRequest;
  resetDetail();
  for (const button of rowList.querySelectorAll("button")) {
    button.setAttribute("aria-pressed", String(button.dataset.id === id));
  }
  message("detail-status", "Loading observation…");
  element("detail-title").focus();
  try {
    const record = await request(observationPath(scope) + "/" + encodeURIComponent(id));
    if (active !== scope || scope.detailRequest !== detailRequest) return;
    message("detail-status", "");
    message("detail-note", record.note);
    message("detail-location", record.location || "Not recorded");
    message("detail-observed", record.observed_at ? dateFull.format(new Date(record.observed_at)) + " UTC" : "Not recorded");
    message("detail-recorded", dateFull.format(new Date(record.recorded_at)) + " UTC");
    message("detail-actor", record.actor_id);
    message("detail-id", record.id);
    element("detail-tag").hidden = false;
    element("detail-body").hidden = false;
  } catch (error) {
    if (active !== scope || scope.detailRequest !== detailRequest) return;
    message("detail-status", "");
    projectError(error, "detail-error");
  }
}

function setCaptureBusy(busy) {
  element("capture-fields").disabled = busy;
  element("save-capture").disabled = busy;
  element("cancel-capture").disabled = busy;
  element("save-capture").textContent = busy ? "Saving…" : "Save observation";
}

function closeCapture() {
  captureDialog.close();
  draft = null;
  captureForm.reset();
  setCaptureBusy(false);
  message("capture-error", "");
}

function openCapture() {
  if (active?.project.permission !== "capture") return;
  draft = { scope: active, payload: null, operation: null, busy: false };
  captureForm.reset();
  setCaptureBusy(false);
  message("capture-error", "");
  element("capture-project").textContent = active.project.name;
  captureDialog.showModal();
}

async function saveObservation(event) {
  event.preventDefault();
  const capture = draft;
  if (!capture || capture.busy || active !== capture.scope) return;
  const fields = new FormData(captureForm);
  const note = fields.get("note");
  if (!note.trim()) {
    message("capture-error", "Enter an observation.");
    element("capture-note").focus();
    return;
  }
  const time = fields.get("observed_at");
  const values = {
    note,
    location: fields.get("location") || null,
    observed_at: time ? new Date(time).toISOString() : null,
  };
  const payload = JSON.stringify(values);
  if (capture.payload !== payload) {
    capture.payload = payload;
    capture.operation = crypto.randomUUID();
  }
  capture.busy = true;
  setCaptureBusy(true);
  message("capture-error", "");
  try {
    const result = await request(observationPath(capture.scope), {
      method: "POST",
      body: { ...values, operation_id: capture.operation },
    });
    if (active !== capture.scope || draft !== capture) return;
    closeCapture();
    message("save-status", "Observation saved.");
    void loadObservations(capture.scope);
    void openObservation(capture.scope, result.id);
  } catch (error) {
    if (active === capture.scope && draft === capture) projectError(error, "capture-error");
  } finally {
    if (draft === capture) {
      capture.busy = false;
      setCaptureBusy(false);
      element("save-capture").focus();
    }
  }
}

signInForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const submit = signInForm.querySelector("button");
  const key = element("access-key");
  submit.disabled = true;
  key.readOnly = true;
  message("sign-in-error", "");
  try {
    await request("/api/session", { method: "POST", body: { key: key.value } });
    showWorkspace(await request("/api/session"));
  } catch (error) {
    message("sign-in-error", errorText(error));
    key.focus();
  } finally {
    key.value = "";
    key.readOnly = false;
    submit.disabled = false;
  }
});

element("sign-out").addEventListener("click", async (event) => {
  const button = event.currentTarget;
  const session = workspace;
  if (!session || session.signingOut) return;
  session.signingOut = true;
  button.disabled = true;
  message("workspace-error", "");
  try {
    await request("/api/session", { method: "DELETE" });
    if (workspace === session) showSignIn();
  } catch (error) {
    if (workspace === session) {
      session.signingOut = false;
      projectError(error, "workspace-error");
    }
  } finally {
    button.disabled = false;
  }
});

projectPicker.addEventListener("change", () => {
  const project = workspace?.projects.find((item) => item.id === projectPicker.value);
  if (project && project !== active?.project) chooseProject(project);
});

element("observations-nav").addEventListener("click", (event) => {
  event.preventDefault();
  element("workspace-content").focus();
});

retryProjects.addEventListener("click", () => {
  if (workspace) void loadProjects(workspace);
});

loadMore.addEventListener("click", () => {
  if (active?.next) void loadObservations(active, active.next);
});

retryLog.addEventListener("click", () => {
  if (active) void loadObservations(active);
});

newObservation.addEventListener("click", openCapture);
captureForm.addEventListener("submit", saveObservation);
element("cancel-capture").addEventListener("click", closeCapture);
captureDialog.addEventListener("cancel", (event) => {
  event.preventDefault();
  if (!draft?.busy) closeCapture();
});

request("/api/session").then(showWorkspace).catch((error) => {
  showSignIn(error.status === 401 ? "" : errorText(error));
});
