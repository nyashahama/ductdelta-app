BEGIN;

SET LOCAL ROLE ductdelta_owner;

ALTER TABLE ductdelta.case_event DROP CONSTRAINT case_event_kind_check;
ALTER TABLE ductdelta.case_event ADD CHECK (kind IN (
    'notice', 'notice_dispatch', 'notice_receipt', 'instruction', 'work',
    'quote', 'decision', 'application', 'certificate', 'receipt', 'allocate',
    'reverse_allocation', 'close', 'reopen'
));

CREATE OR REPLACE FUNCTION ductdelta.case_financial(requested_case uuid, bank_access boolean) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'currency', 'ZAR', 'basis', 'excl_vat',
        'proposed', proposed::text, 'agreed', agreed::text, 'unresolved', unresolved::text,
        'unresolved_lines', unresolved_lines, 'quote_awaiting_decision', quote_awaiting_decision,
        'certified', certified::text, 'retained', retained::text, 'payable', payable::text,
        'matched', matched::text, 'outstanding', outstanding::text,
        'unallocated', CASE WHEN bank_access THEN unallocated::text END
    )
    FROM ductdelta.case_totals(requested_case);
$$;

CREATE OR REPLACE FUNCTION ductdelta.case_validate_close(item ductdelta.change_case, outcome text) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    totals record;
BEGIN
    IF outcome NOT IN ('settled', 'no_change', 'withdrawn', 'rejected') THEN
        RAISE EXCEPTION 'Unknown closeout outcome' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO STRICT totals FROM ductdelta.case_totals(item.id);
    IF EXISTS (
        SELECT FROM ductdelta.case_event AS notice
        WHERE notice.case_id = item.id AND notice.kind = 'notice' AND NOT EXISTS (
            SELECT FROM ductdelta.case_event AS dispatch
            WHERE dispatch.case_id = item.id AND dispatch.kind = 'notice_dispatch'
              AND dispatch.subject_id = notice.id
        )
    ) THEN
        RAISE EXCEPTION 'An issued notice still needs a dispatch record' USING ERRCODE = '23514';
    END IF;
    IF totals.quote_awaiting_decision OR totals.unresolved_lines > 0 THEN
        RAISE EXCEPTION 'Every quote line needs a final disposition' USING ERRCODE = 'DD003';
    END IF;
    IF outcome <> 'settled' THEN
        IF EXISTS (
            SELECT FROM ductdelta.case_event WHERE case_id = item.id
            AND kind IN ('instruction', 'application', 'certificate', 'receipt')
        ) OR coalesce(totals.agreed, 0) <> 0 THEN
            RAISE EXCEPTION 'Recorded work or finance requires settlement' USING ERRCODE = '23514';
        END IF;
        RETURN;
    END IF;

    IF NOT coalesce((
        SELECT bool_and(latest.completed IS TRUE)
        FROM ductdelta.case_event AS instruction
        LEFT JOIN (
            SELECT DISTINCT ON (subject_id) subject_id, (data ->> 'completed')::boolean AS completed
            FROM ductdelta.case_event
            WHERE case_id = item.id AND kind = 'work' AND subject_id IS NOT NULL
            ORDER BY subject_id, sequence DESC
        ) AS latest ON latest.subject_id = instruction.id
        WHERE instruction.case_id = item.id AND instruction.kind = 'instruction'
    ), false) THEN
        RAISE EXCEPTION 'Record completed work for each direction' USING ERRCODE = '23514';
    END IF;
    IF totals.agreed IS NULL OR totals.agreed <> totals.certified
       OR totals.retained <> 0 OR totals.outstanding <> 0 OR totals.unallocated <> 0 THEN
        RAISE EXCEPTION 'Resolve open financial items before closing the case' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT FROM ductdelta.case_certificate AS cert
        WHERE cert.case_id = item.id AND cert.payable <> coalesce((
            SELECT sum(amount) FROM ductdelta.case_allocation AS allocation
            WHERE (allocation.case_id, allocation.certificate_id) = (cert.case_id, cert.id)
        ), 0)
    ) THEN
        RAISE EXCEPTION 'Resolve each payable before closing the case' USING ERRCODE = '23514';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION ductdelta.web_case_action(
    session_digest bytea, requested_project uuid, requested_case uuid, requested_operation uuid,
    action_kind text, payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, true);
    item ductdelta.change_case;
    event ductdelta.case_event;
    capability_needed text;
    event_reference text;
    event_subject uuid;
    agreement_reference text;
    due_at text;
BEGIN
    IF requested_operation IS NULL OR jsonb_typeof(payload) IS DISTINCT FROM 'object'
       OR octet_length(payload::text) > 65536 THEN
        RAISE EXCEPTION 'Invalid case action' USING ERRCODE = '22023';
    END IF;

    CASE action_kind
        WHEN 'notice', 'notice_dispatch', 'notice_receipt', 'instruction' THEN capability_needed := 'direction';
        WHEN 'quote', 'decision', 'application', 'close', 'reopen' THEN capability_needed := 'commercial';
        WHEN 'certificate', 'receipt', 'allocate', 'reverse_allocation' THEN capability_needed := 'finance';
        WHEN 'work' THEN
            IF member.permission <> 'capture' THEN
                RAISE EXCEPTION 'Capture permission required' USING ERRCODE = '42501';
            END IF;
        ELSE RAISE EXCEPTION 'Unknown case action' USING ERRCODE = '22023';
    END CASE;
    IF capability_needed IS NOT NULL THEN
        PERFORM FROM ductdelta.project_workflow_grant
        WHERE (organization_id, project_id, actor_id, capability) =
              (member.organization_id, member.project_id, member.actor_id, capability_needed)
        FOR SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Case action requires a project grant' USING ERRCODE = '42501';
        END IF;
    END IF;

    -- One lock serializes every decision, posting and closeout within this case.
    SELECT * INTO item FROM ductdelta.change_case
    WHERE (organization_id, project_id, id) = (member.organization_id, member.project_id, requested_case)
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Case unavailable' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO event FROM ductdelta.case_event
    WHERE (case_id, actor_id, operation_id) = (item.id, member.actor_id, requested_operation);
    IF FOUND THEN
        IF (event.kind, event.data) IS DISTINCT FROM (action_kind, payload) THEN
            RAISE EXCEPTION 'Operation ID already records a different action' USING ERRCODE = 'DD001';
        END IF;
        RETURN jsonb_build_object('id', event.id);
    END IF;
    IF item.closeout_id IS NOT NULL AND action_kind NOT IN ('reverse_allocation', 'reopen') THEN
        RAISE EXCEPTION 'Case is closed' USING ERRCODE = '23514';
    END IF;

    CASE action_kind
        WHEN 'notice' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['reference', 'agreement', 'body', 'due_at']);
            event_reference := ductdelta.case_text(payload, 'reference', 160);
            agreement_reference := ductdelta.case_text(payload, 'agreement', 160);
            PERFORM ductdelta.case_text(payload, 'body', 12000);
            IF payload ? 'due_at' THEN
                due_at := ductdelta.case_text(payload, 'due_at', 40);
                IF due_at !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$' THEN
                    RAISE EXCEPTION 'Notice deadline requires a date and offset' USING ERRCODE = '22023';
                END IF;
                PERFORM due_at::timestamptz;
            END IF;
        WHEN 'instruction' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['reference', 'agreement', 'scope']);
            event_reference := ductdelta.case_text(payload, 'reference', 160);
            agreement_reference := ductdelta.case_text(payload, 'agreement', 160);
            PERFORM ductdelta.case_text(payload, 'scope', 8000);
        WHEN 'notice_dispatch', 'notice_receipt' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['reference', 'notice']);
            event_reference := ductdelta.case_text(payload, 'reference', 160);
            event_subject := ductdelta.case_text(payload, 'notice', 36)::uuid;
            PERFORM ductdelta.case_assert_event(item.id, event_subject, 'notice');
            IF action_kind = 'notice_receipt' AND NOT EXISTS (
                SELECT FROM ductdelta.case_event
                WHERE (case_id, kind, subject_id) = (item.id, 'notice_dispatch', event_subject)
            ) THEN
                RAISE EXCEPTION 'Record dispatch before acknowledgement' USING ERRCODE = '23514';
            END IF;
        WHEN 'work' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['description', 'completed', 'instruction']);
            PERFORM ductdelta.case_text(payload, 'description', 8000);
            IF jsonb_typeof(payload -> 'completed') IS DISTINCT FROM 'boolean' THEN
                RAISE EXCEPTION 'Work completion must be explicit' USING ERRCODE = '22023';
            END IF;
            IF payload ? 'instruction' THEN
                event_subject := ductdelta.case_text(payload, 'instruction', 36)::uuid;
                PERFORM ductdelta.case_assert_event(item.id, event_subject, 'instruction');
            END IF;
        WHEN 'reopen' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['reason']);
            PERFORM ductdelta.case_text(payload, 'reason', 4000);
            IF item.closeout_id IS NULL THEN
                RAISE EXCEPTION 'Case is already open' USING ERRCODE = '23514';
            END IF;
            event_subject := item.closeout_id;
        ELSE
            RETURN ductdelta.case_ledger_action(item, member.actor_id, requested_operation, action_kind, payload);
    END CASE;

    IF agreement_reference IS NOT NULL THEN
        IF item.agreement IS NOT NULL AND item.agreement <> agreement_reference THEN
            RAISE EXCEPTION 'Agreement does not match the case' USING ERRCODE = '23514';
        END IF;
        UPDATE ductdelta.change_case SET agreement = agreement_reference WHERE id = item.id;
    END IF;
    INSERT INTO ductdelta.case_event (
        organization_id, project_id, case_id, actor_id, operation_id, kind, subject_id, reference, data
    ) VALUES (
        item.organization_id, item.project_id, item.id, member.actor_id, requested_operation,
        action_kind, event_subject, event_reference, payload
    ) RETURNING * INTO event;
    IF action_kind = 'reopen' THEN
        UPDATE ductdelta.change_case SET closeout_id = NULL WHERE id = item.id;
    END IF;
    RETURN jsonb_build_object('id', event.id);
END;
$$;

COMMIT;
