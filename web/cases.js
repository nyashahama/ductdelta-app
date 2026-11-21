(() => {
  "use strict";

  const caseView = element("cases-view");
  const caseList = element("case-list");
  const caseDetail = element("case-detail");
  const actionForm = element("case-action-form");
  const actionSelect = element("case-action");
  const actionFields = element("case-action-fields");
  const actionSubmit = element("submit-case-action");
  const createDialog = element("case-dialog");
  const createForm = element("case-create-form");
  const createSubmit = element("case-create-submit");
  const createCancel = element("case-create-cancel");
  const amountPattern = "-?(0|[1-9][0-9]{0,11})([.][0-9]{1,2})?";

  const actions = {
    notice: ["Record notice", "direction", "Notice"],
    notice_dispatch: ["Record notice dispatch", "direction", "Notice dispatched"],
    notice_receipt: ["Record notice acknowledgement", "direction", "Notice acknowledged"],
    instruction: ["Record instruction", "direction", "Instruction"],
    work: ["Record work", "capture", "Work record"],
    quote: ["Record quote", "commercial", "Quote"],
    decision: ["Decide quote", "commercial", "Quote decision"],
    application: ["Record payment application", "commercial", "Payment application"],
    certificate: ["Record certificate", "finance", "Certificate"],
    receipt: ["Record cash receipt", "finance", "Receipt"],
    allocate: ["Allocate receipt", "finance", "Receipt allocation"],
    reverse_allocation: ["Reverse allocation", "finance", "Allocation reversal"],
    close: ["Close case", "commercial", "Closeout"],
  };

  const moneyLabels = {
    proposed: "Proposed", agreed: "Agreed", unresolved: "Unresolved",
    certified: "Certified", retained: "Retention held", payable: "Payable",
    matched: "Cash matched", outstanding: "Outstanding", unallocated: "Unallocated cash",
  };
  const dispositions = [["open", "Open"], ["disputed", "Disputed"], ["waived", "Remainder waived"], ["accepted", "Accepted in full"]];
  const outcomes = [["settled", "Settled"], ["no_change", "No change"], ["withdrawn", "Withdrawn"], ["rejected", "Rejected"]];

  let scope = null;
  let createDraft = null;
  let actionDraft = null;

  function node(tag, text = "", className = "") {
    const result = document.createElement(tag);
    result.textContent = text;
    if (className) result.className = className;
    return result;
  }

  function casePath(context, id) {
    const root = "/api/projects/" + encodeURIComponent(context.project.id) + "/cases";
    return id ? root + "/" + encodeURIComponent(id) : root;
  }

  function showCases(open, focus = true) {
    caseView.hidden = !open;
    element("observations-view").hidden = open;
    for (const [id, current] of [["cases-nav", open], ["observations-nav", !open]]) {
      if (current) element(id).setAttribute("aria-current", "page");
      else element(id).removeAttribute("aria-current");
    }
    if (focus) element(open ? "cases-title" : "workspace-content").focus();
    if (open && scope && !scope.loaded && !scope.listRequest) void loadList(scope);
  }

  function displayList(context) {
    caseList.replaceChildren(...context.cases.map((item) => {
      const button = node("button");
      button.type = "button";
      button.setAttribute("aria-label", item.title);
      button.setAttribute("aria-pressed", String(item.id === context.selected));
      button.append(node("span", item.title),
        node("span", item.closed ? "Closed" : "Open", item.closed ? "tag status-closed" : "tag"));
      button.addEventListener("click", () => void loadCase(context, item.id, true));
      const row = node("li");
      row.append(button);
      return row;
    }));
    element("case-list-more-bar").hidden = !context.nextBefore;
    const count = context.cases.length;
    message("case-count", count ? count + (count === 1 ? " case" : " cases") : "");
    message("case-list-status", count ? "" : "No change cases have been recorded for this project.");
  }

  async function loadList(context, before = null) {
    const revision = {};
    context.listRequest = revision;
    element("case-list-more").disabled = true;
    element("case-list-retry-bar").hidden = true;
    message("case-error", "");
    if (!context.loaded) message("case-list-status", "Loading change cases…");
    try {
      const suffix = before ? "?before=" + encodeURIComponent(before) : "";
      const page = await request(casePath(context) + suffix);
      if (scope !== context || context.listRequest !== revision) return;
      context.cases = before ? context.cases.concat(page.cases) : page.cases;
      context.nextBefore = page.next_before;
      context.loaded = true;
      displayList(context);
    } catch (error) {
      if (scope !== context || context.listRequest !== revision) return;
      message("case-list-status", "");
      projectError(error, "case-error");
      if (scope === context) element("case-list-retry-bar").hidden = false;
    } finally {
      if (context.listRequest === revision) {
        context.listRequest = null;
        if (scope === context) element("case-list-more").disabled = false;
      }
    }
  }

  function clearDetails() {
    caseDetail.hidden = true;
    element("case-title").textContent = "";
    element("case-agreement").textContent = "";
    element("case-id").textContent = "";
    element("case-timeline").replaceChildren();
    element("case-financial-data").replaceChildren();
    actionFields.replaceChildren();
    actionSelect.replaceChildren();
    actionDraft = null;
    message("case-action-error", "");
  }

  async function loadCase(context, id, focus) {
    if (scope !== context) return;
    const revision = {};
    context.detailRequest = revision;
    context.selected = id;
    context.detail = null;
    clearDetails();
    if (context.loaded) displayList(context);
    message("case-error", "");
    message("case-detail-status", "Loading case record…");
    try {
      const record = await request(casePath(context, id));
      if (scope !== context || context.detailRequest !== revision) return;
      context.detail = record;
      const row = context.cases.find((item) => item.id === id);
      if (row) row.closed = record.closed;
      if (context.loaded) displayList(context);
      renderCase(context);
      if (focus && !caseView.hidden) element("case-title").focus();
    } catch (error) {
      if (scope !== context || context.detailRequest !== revision) return;
      projectError(error, "case-error");
      if (scope === context) message("case-detail-status", "Select the case to try again.");
    }
  }

  function decimal(value) {
    const [integer, fraction] = value.split(".");
    const whole = integer.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    return fraction === undefined ? whole : whole + "." + fraction;
  }

  function dataPair(label, value) {
    const group = node("div");
    group.append(node("dt", label), node("dd", value));
    return group;
  }

  function renderMoney(financial) {
    element("case-financial").hidden = !financial;
    if (!financial) return;
    message("case-quote-pending", financial.quote_awaiting_decision
      ? "The latest quote is awaiting a decision." : "");
    element("case-currency").textContent = financial.currency + (financial.basis === "excl_vat" ? " · Excl. VAT" : "");
    for (const [key, label] of Object.entries(moneyLabels)) {
      const value = financial[key];
      if (key === "unallocated" && value == null) continue;
      const item = dataPair(label, value == null ? "Not recorded" : decimal(value));
      if (value == null) item.lastChild.className = "unrecorded";
      if (key === "outstanding") item.className = "balance";
      element("case-financial-data").append(item);
    }
  }

  const eventReferenceKeys = new Set(["notice", "instruction", "quote", "predecessor", "application", "receipt", "certificate", "allocation"]);
  const eventLabels = {
    reference: "Reference", agreement: "Agreement", scope: "Authorized scope", body: "Notice text", due_at: "Due",
    notice: "Notice", instruction: "Instruction", description: "Work performed", completed: "Completion",
    quote: "Quote", reason: "Reason", amount: "Amount", cumulative: "Cumulative certified",
    withheld: "Retention withheld", released: "Retention released", predecessor: "Earlier certificate",
    application: "Payment application", receipt: "Cash receipt", certificate: "Certificate",
    allocation: "Allocation", outcome: "Outcome",
  };
  const amountFields = new Set(["amount", "cumulative", "withheld", "released"]);

  function eventTitle(event) {
    const label = actions[event.kind]?.[2] || "Case event";
    return event.data.reference ? label + " " + event.data.reference : label;
  }

  function eventLines(event) {
    const decision = event.kind === "decision";
    const container = node("div", "", "event-lines");
    const table = node("table");
    const header = table.createTHead().insertRow();
    for (const title of decision ? ["Line", "Accepted", "Disposition"] : ["Description", "Amount"]) {
      const cell = node("th", title);
      cell.scope = "col";
      header.append(cell);
    }
    const body = table.createTBody();
    for (const line of event.data.lines) {
      const row = body.insertRow();
      const values = decision
        ? [String(line.line), decimal(line.accepted), dispositions.find(([value]) => value === line.disposition)?.[1] || line.disposition]
        : [line.description, decimal(line.amount)];
      for (const value of values) row.insertCell().textContent = value;
    }
    container.append(table);
    return container;
  }

  function renderTimeline(events) {
    const references = new Map(events.map((event) => [event.id, eventTitle(event)]));
    element("case-timeline-empty").hidden = events.length !== 0;
    for (const event of events) {
      const item = node("li");
      const detail = node("details");
      const heading = node("summary");
      heading.append(node("span", eventTitle(event)));
      const time = node("time", dateFull.format(new Date(event.recorded_at)) + " UTC");
      time.dateTime = event.recorded_at;
      const fields = node("dl", "", "event-data");
      for (const [key, label] of Object.entries(eventLabels)) {
        const value = event.data[key];
        if (value === undefined) continue;
        let display = String(value);
        if (eventReferenceKeys.has(key)) display = references.get(value) || display;
        if (amountFields.has(key)) display = decimal(display);
        if (key === "completed") display = value ? "Complete" : "In progress";
        if (key === "outcome") display = outcomes.find(([id]) => id === value)?.[1] || display;
        if (key === "due_at") display = dateFull.format(new Date(value)) + " UTC";
        fields.append(dataPair(label, display));
      }
      for (const [key, value] of Object.entries(event.data.financial_snapshot || {})) {
        if (value != null && (moneyLabels[key] || key === "work_delta")) {
          fields.append(dataPair(moneyLabels[key] || "Certified this period", decimal(value)));
        }
      }
      heading.append(time);
      detail.append(heading, fields);
      if (event.data.lines?.length) detail.append(eventLines(event));
      detail.append(node("p", "Recorded by " + event.actor_id, "event-actor"));
      item.append(detail);
      element("case-timeline").append(item);
    }
  }

  function currentEvents(record, kind) {
    return record.events.filter((event) => event.kind === kind);
  }

  function eligibleEvents(record, kind) {
    const events = currentEvents(record, kind);
    if (kind === "allocate") {
      const reversed = new Set(currentEvents(record, "reverse_allocation").map((event) => event.data.allocation));
      return events.filter((event) => !reversed.has(event.id));
    }
    return events;
  }

  function availableActions(context) {
    const record = context.detail;
    const grants = new Set(record.capabilities);
    if (context.project.permission === "capture") grants.add("capture");
    return Object.entries(actions).filter(([kind, [, grant]]) => {
      if (!grants.has(grant)) return false;
      if (kind === "reverse_allocation") return eligibleEvents(record, "allocate").length > 0;
      if (record.closed) return false;
      if (kind === "notice_dispatch") return currentEvents(record, "notice").length > 0;
      if (kind === "notice_receipt") return currentEvents(record, "notice_dispatch").length > 0;
      if (kind === "close") return true;
      if (["commercial", "finance"].includes(grant) && !record.agreement) return false;
      if (kind === "decision") return currentEvents(record, "quote").length > 0;
      if (kind === "allocate") return currentEvents(record, "receipt").length > 0 && currentEvents(record, "certificate").length > 0;
      return true;
    });
  }

  function renderCase(context) {
    const record = context.detail;
    caseDetail.hidden = false;
    element("case-title").textContent = record.title;
    element("case-status").textContent = record.closed ? "Closed" : "Open";
    element("case-status").classList.toggle("status-closed", record.closed);
    element("case-id").textContent = record.id;
    element("case-agreement").textContent = record.agreement || "Not recorded";
    element("case-source").hidden = !record.observation_id;
    renderMoney(record.financial);
    renderTimeline(record.events);
    const available = availableActions(context);
    element("case-actions").hidden = available.length === 0;
    actionSelect.replaceChildren(new Option("Choose an action", ""), ...available.map(([key, [label]]) => new Option(label, key)));
    actionSubmit.hidden = true;
    actionSubmit.disabled = false;
    actionSubmit.textContent = "Record action";
    actionSelect.disabled = false;
    actionFields.disabled = false;
    message("case-detail-status", "");
  }

  function field(parent, name, label, settings = {}) {
    const group = node("div", "", "field");
    const id = "action-" + name;
    const caption = node("label", label);
    caption.htmlFor = id;
    if (settings.optional) caption.append(node("span", "optional", "optional"));
    const input = node(settings.options ? "select" : settings.multiline ? "textarea" : "input");
    input.id = id;
    input.name = name;
    input.required = !settings.optional;
    if (settings.options) {
      input.append(new Option(settings.optional ? "None" : "Choose " + label.toLowerCase(), ""));
      input.append(...settings.options.map(([value, text]) => new Option(text, value)));
    } else if (settings.multiline) {
      input.rows = 4;
    } else {
      input.type = settings.date ? "datetime-local" : "text";
    }
    if (settings.limit) input.maxLength = settings.limit;
    if (settings.money) {
      input.pattern = amountPattern;
      input.maxLength = 16;
      input.title = "Use up to twelve whole digits and two decimal places, without commas.";
    }
    if (settings.value !== undefined) input.value = settings.value;
    if (settings.readOnly) input.readOnly = true;
    group.append(caption, input);
    parent.append(group);
    return input;
  }

  function actionReference(label) {
    field(actionFields, "reference", label, { limit: 160 });
  }

  function eventField(name, label, events, options = {}) {
    return field(actionFields, name, label, {
      ...options,
      options: [...events].reverse().map((event) => [event.id, eventTitle(event)]),
    });
  }

  function agreementField(record) {
    field(actionFields, "agreement", "Agreement reference", {
      value: record.agreement || "", readOnly: Boolean(record.agreement), limit: 160,
    });
  }

  function quoteFields() {
    const lines = node("div");
    lines.id = "quote-lines";
    const help = node("p", "Enter credits as negative amounts. Use a decimal point and omit commas.", "case-fields-text support");
    const add = node("button", "Add quote line", "button secondary quote-add");
    add.type = "button";
    const refreshLines = () => {
      const rows = [...lines.children];
      rows.forEach((row, index) => {
        const number = index + 1;
        row.querySelector("legend").textContent = "Line " + number;
        const values = [["description", "Description for line "], ["price", "Amount for line "]];
        for (const [key, label] of values) {
          const input = row.querySelector("[data-quote-" + key + "]");
          input.id = "action-line-" + key + "-" + number;
          const caption = input.previousElementSibling;
          caption.htmlFor = input.id;
          caption.textContent = label + number;
        }
        const remove = row.querySelector("button");
        remove.setAttribute("aria-label", "Remove quote line " + number);
        remove.hidden = rows.length === 1;
      });
      add.disabled = rows.length === 99;
    };
    const addLine = (focus) => {
      const row = node("fieldset", "", "case-line");
      row.append(node("legend"));
      const description = field(row, "line-description", "", { limit: 2000 });
      description.dataset.quoteDescription = "";
      const amount = field(row, "line-amount", "", { money: true });
      amount.dataset.quotePrice = "";
      const remove = node("button", "Remove line", "button secondary");
      remove.type = "button";
      remove.addEventListener("click", () => {
        row.remove();
        refreshLines();
        add.focus();
      });
      row.append(remove);
      lines.append(row);
      refreshLines();
      if (focus) description.focus();
    };
    add.addEventListener("click", () => addLine(true));
    actionFields.append(help, lines, add);
    addLine(false);
  }

  function decisionFields(record) {
    const quote = currentEvents(record, "quote").at(-1);
    if (!quote) return;
    eventField("quote", "Quote", [quote], { value: quote.id });
    const previous = currentEvents(record, "decision").findLast((event) => event.data.quote === quote.id);
    for (const [index, line] of quote.data.lines.entries()) {
      const number = index + 1;
      const lineFields = node("fieldset", "", "case-line");
      lineFields.dataset.decisionLine = number;
      lineFields.append(node("legend", "Line " + number),
        node("p", line.description), node("p", "Proposed " + decimal(line.amount), "support"));
      const saved = previous?.data.lines.find((item) => item.line === number);
      field(lineFields, "accepted-" + number, "Accepted amount for line " + number, {
        money: true, value: saved?.accepted || "0",
      });
      field(lineFields, "disposition-" + number, "Disposition for line " + number, {
        options: dispositions, value: saved?.disposition || "open",
      });
      actionFields.append(lineFields);
    }
    field(actionFields, "reason", "Decision reason", { multiline: true, limit: 4000 });
  }

  function workFields(record) {
    field(actionFields, "description", "Work performed", { multiline: true, limit: 8000 });
    eventField("instruction", "Instruction", currentEvents(record, "instruction"), { optional: true });
    field(actionFields, "completed", "Work status", { options: [["false", "In progress"], ["true", "Complete"]] });
  }

  function certificateFields(record) {
    actionReference("Certificate reference");
    const latest = currentEvents(record, "certificate").at(-1);
    if (latest) eventField("predecessor", "Previous certificate", [latest], { value: latest.id });
    eventField("application", "Payment application", currentEvents(record, "application"), { optional: true });
    field(actionFields, "cumulative", "Cumulative certified amount", { money: true });
    field(actionFields, "withheld", "Retention withheld this period", { money: true, value: "0" });
    field(actionFields, "released", "Retention released this period", { money: true, value: "0" });
    field(actionFields, "reason", "Reason", { optional: true, multiline: true, limit: 4000 });
  }

  function renderAction(kind, record) {
    actionFields.replaceChildren();
    message("case-action-error", "");
    actionSubmit.hidden = !kind;
    if (!kind) return;
    switch (kind) {
      case "notice":
        actionReference("Notice reference");
        agreementField(record);
        field(actionFields, "body", "Notice text", { multiline: true, limit: 12000 });
        field(actionFields, "due_at", "Due on this device", { optional: true, date: true });
        break;
      case "notice_dispatch":
      case "notice_receipt": {
        const dispatched = new Set(currentEvents(record, "notice_dispatch").map((event) => event.data.notice));
        const notices = currentEvents(record, "notice").filter((event) => kind === "notice_dispatch" || dispatched.has(event.id));
        eventField("notice", "Notice", notices);
        actionReference(kind === "notice_dispatch" ? "Dispatch reference" : "Acknowledgement reference");
        break;
      }
      case "instruction":
        actionReference("Instruction reference");
        agreementField(record);
        field(actionFields, "scope", "Authorized scope", { multiline: true, limit: 8000 });
        break;
      case "work": workFields(record); break;
      case "quote":
        actionReference("Quote reference");
        quoteFields();
        break;
      case "decision": decisionFields(record); break;
      case "application":
        actionReference("Application reference");
        field(actionFields, "amount", "Applied amount", { money: true });
        break;
      case "certificate": certificateFields(record); break;
      case "receipt":
        actionReference("Receipt reference");
        field(actionFields, "amount", "Receipt amount", { money: true });
        break;
      case "allocate":
        eventField("receipt", "Cash receipt", currentEvents(record, "receipt"));
        eventField("certificate", "Certificate", currentEvents(record, "certificate"));
        field(actionFields, "amount", "Allocation amount", { money: true });
        actionReference("Allocation reference");
        break;
      case "reverse_allocation":
        eventField("allocation", "Allocation", eligibleEvents(record, "allocate"));
        field(actionFields, "reason", "Reversal reason", { multiline: true, limit: 4000 });
        break;
      case "close":
        field(actionFields, "outcome", "Outcome", { options: outcomes });
        field(actionFields, "reason", "Closeout reason", { multiline: true, limit: 4000 });
        break;
    }
  }

  function actionPayload(kind) {
    const values = new FormData(actionForm);
    values.delete("kind");
    const data = Object.fromEntries([...values].filter(([key, value]) => value.trim() && !key.startsWith("line-")));
    if (kind === "quote") {
      data.lines = [...element("quote-lines").children].map((row) => ({
        description: row.querySelector("[data-quote-description]").value,
        amount: row.querySelector("[data-quote-price]").value,
      }));
    }
    if (kind === "decision") {
      data.lines = [...actionFields.querySelectorAll("[data-decision-line]")].map((row) => {
        const line = Number(row.dataset.decisionLine);
        const accepted = "accepted-" + line;
        const disposition = "disposition-" + line;
        delete data[accepted];
        delete data[disposition];
        return { line, accepted: values.get(accepted), disposition: values.get(disposition) };
      });
    }
    if (kind === "work") data.completed = data.completed === "true";
    if (data.due_at) data.due_at = new Date(data.due_at).toISOString();
    return data;
  }

  function operationId(draft, values) {
    const payload = JSON.stringify(values);
    if (draft.payload !== payload) {
      draft.payload = payload;
      draft.operation = crypto.randomUUID();
    }
    return draft.operation;
  }

  function busyAction(busy) {
    actionFields.disabled = busy;
    actionSelect.disabled = busy;
    actionSubmit.disabled = busy;
    actionSubmit.textContent = busy ? "Recording…" : "Record action";
  }

  async function saveAction(event) {
    event.preventDefault();
    const draft = actionDraft;
    if (!draft || draft.busy) return;
    const { context, record, kind } = draft;
    const data = actionPayload(kind);
    const operation_id = operationId(draft, { kind, data });
    draft.busy = true;
    busyAction(true);
    message("case-action-error", "");
    try {
      await request(casePath(context, record.id) + "/actions", {
        method: "POST", body: { operation_id, kind, data },
      });
      if (scope !== context || context.detail !== record) return;
      message("case-save-status", actions[kind][0] + " saved.");
      void loadCase(context, record.id, !caseView.hidden);
      void loadList(context);
    } catch (error) {
      if (scope === context && context.detail === record) projectError(error, "case-action-error");
    } finally {
      if (actionDraft === draft) {
        draft.busy = false;
        busyAction(false);
        actionSubmit.focus();
      }
    }
  }

  function busyCreate(busy) {
    element("case-create-title").readOnly = busy;
    createSubmit.disabled = busy;
    createCancel.disabled = busy;
    createSubmit.textContent = busy ? "Creating…" : "Create case";
  }

  function closeCreate() {
    createDialog.close();
    createDraft = null;
    createForm.reset();
    busyCreate(false);
    message("case-create-error", "");
  }

  function openCreate(observationId = null) {
    if (scope?.project.permission !== "capture") return;
    createDraft = { context: scope, observationId, busy: false };
    createForm.reset();
    message("case-create-error", "");
    element("case-create-context").textContent = scope.project.name + (observationId ? " · Linked to this observation" : "");
    createDialog.showModal();
  }

  async function saveCase(event) {
    event.preventDefault();
    const draft = createDraft;
    if (!draft || draft.busy) return;
    const title = element("case-create-title").value.trim();
    if (!title) {
      message("case-create-error", "Enter a case title.");
      return;
    }
    const data = { title };
    if (draft.observationId) data.observation_id = draft.observationId;
    const operation_id = operationId(draft, data);
    draft.busy = true;
    busyCreate(true);
    message("case-create-error", "");
    try {
      const result = await request(casePath(draft.context), {
        method: "POST", body: { operation_id, ...data },
      });
      if (draft !== createDraft || scope !== draft.context) return;
      closeCreate();
      showCases(true);
      void loadList(draft.context);
      void loadCase(draft.context, result.id, true);
    } catch (error) {
      if (draft === createDraft && scope === draft.context) projectError(error, "case-create-error");
    } finally {
      if (draft === createDraft) {
        draft.busy = false;
        busyCreate(false);
        createSubmit.focus();
      }
    }
  }

  document.addEventListener("ductdelta:project-changed", (event) => {
    if (createDialog.open) closeCreate();
    const project = event.detail.project;
    scope = project ? { project, cases: [], loaded: false, selected: null, detail: null } : null;
    element("new-case").hidden = project?.permission !== "capture";
    element("case-list-retry-bar").hidden = true;
    element("case-list-more-bar").hidden = true;
    caseList.replaceChildren();
    clearDetails();
    message("case-error", "");
    message("case-count", "");
    message("case-save-status", "");
    message("case-list-status", "Select a project to view its change cases.");
    message("case-detail-status", "Select a case to open its record.");
    if (!scope) showCases(false, false);
    else if (!caseView.hidden) void loadList(scope);
  });

  element("cases-nav").addEventListener("click", (event) => {
    event.preventDefault();
    showCases(true);
  });
  element("observations-nav").addEventListener("click", () => showCases(false));
  element("case-list-more").addEventListener("click", () => {
    if (scope?.nextBefore && !scope.listRequest) void loadList(scope, scope.nextBefore);
  });
  element("case-list-retry").addEventListener("click", () => {
    if (scope) void loadList(scope);
  });
  element("new-case").addEventListener("click", () => openCreate());
  element("case-from-observation").addEventListener("click", (event) => openCreate(event.currentTarget.dataset.observation));
  element("case-source").addEventListener("click", () => {
    const observationId = scope?.detail?.observation_id;
    if (!observationId) return;
    showCases(false, false);
    document.dispatchEvent(new CustomEvent("ductdelta:open-observation", {
      detail: { projectId: scope.project.id, observationId },
    }));
  });
  createForm.addEventListener("submit", saveCase);
  createCancel.addEventListener("click", closeCreate);
  createDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    if (!createDraft?.busy) closeCreate();
  });
  actionSelect.addEventListener("change", () => {
    if (!scope?.detail) return;
    actionDraft = actionSelect.value ? { context: scope, record: scope.detail, kind: actionSelect.value, busy: false } : null;
    renderAction(actionSelect.value, scope.detail);
  });
  actionForm.addEventListener("submit", saveAction);
})();
