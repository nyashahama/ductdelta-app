BEGIN;

SET LOCAL ROLE ductdelta_owner;

ALTER TABLE ductdelta.case_receipt
    ADD COLUMN organization_id uuid,
    ADD COLUMN project_id uuid,
    ADD COLUMN allocated numeric(18, 2) NOT NULL DEFAULT 0,
    ADD COLUMN shared boolean NOT NULL DEFAULT false;

UPDATE ductdelta.case_receipt AS receipt
SET organization_id = item.organization_id, project_id = item.project_id,
    allocated = coalesce((
        SELECT sum(amount) FROM ductdelta.case_allocation
        WHERE (case_id, receipt_id) = (receipt.case_id, receipt.id)
    ), 0)
FROM ductdelta.change_case AS item WHERE item.id = receipt.case_id;

ALTER TABLE ductdelta.case_receipt
    ALTER COLUMN organization_id SET NOT NULL,
    ALTER COLUMN project_id SET NOT NULL,
    ADD UNIQUE (organization_id, id),
    ADD FOREIGN KEY (organization_id, project_id, case_id)
        REFERENCES ductdelta.change_case (organization_id, project_id, id),
    ADD CHECK (allocated BETWEEN 0 AND amount);

ALTER TABLE ductdelta.case_allocation ADD COLUMN organization_id uuid, ADD COLUMN project_id uuid;
UPDATE ductdelta.case_allocation AS allocation
SET organization_id = item.organization_id, project_id = item.project_id
FROM ductdelta.change_case AS item WHERE item.id = allocation.case_id;

ALTER TABLE ductdelta.case_allocation
    ALTER COLUMN organization_id SET NOT NULL,
    ALTER COLUMN project_id SET NOT NULL,
    DROP CONSTRAINT case_allocation_case_id_receipt_id_fkey,
    ADD FOREIGN KEY (organization_id, project_id, case_id)
        REFERENCES ductdelta.change_case (organization_id, project_id, id),
    ADD FOREIGN KEY (organization_id, receipt_id)
        REFERENCES ductdelta.case_receipt (organization_id, id);

CREATE FUNCTION ductdelta.case_finance_receipt(
    company_id uuid, requesting_actor uuid, requested_receipt uuid
) RETURNS uuid
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    source_case uuid;
BEGIN
    SELECT receipt.case_id INTO source_case
    FROM ductdelta.case_receipt AS receipt
    JOIN ductdelta.project_workflow_grant AS finance
      ON (finance.organization_id, finance.project_id) = (receipt.organization_id, receipt.project_id)
    WHERE (receipt.organization_id, receipt.id) = (company_id, requested_receipt)
      AND finance.actor_id = requesting_actor AND finance.capability = 'finance'
    FOR SHARE OF finance;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receipt unavailable' USING ERRCODE = '42501';
    END IF;
    RETURN source_case;
END;
$$;

CREATE FUNCTION ductdelta.case_reserve_receipt(
    company_id uuid, requested_receipt uuid, destination_case uuid, cash_delta numeric
) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    -- A row update serializes reservations by receipt across all destination cases.
    UPDATE ductdelta.case_receipt
    SET allocated = allocated + cash_delta, shared = shared OR case_id <> destination_case
    WHERE (organization_id, id) = (company_id, requested_receipt)
      AND allocated + cash_delta BETWEEN 0 AND amount;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Allocation exceeds available receipt' USING ERRCODE = '23514';
    END IF;
END;
$$;

CREATE FUNCTION ductdelta.case_bank_receipts(company_id uuid, requesting_actor uuid, destination_case uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp
AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', receipt.id, 'reference', event.reference, 'available', (receipt.amount - receipt.allocated)::text,
        'case_id', receipt.case_id, 'case_title', item.title, 'project_name', project.name
    ) ORDER BY event.recorded_at DESC, event.id), '[]'::jsonb)
    FROM ductdelta.case_receipt AS receipt
    JOIN ductdelta.case_event AS event ON (event.case_id, event.id) = (receipt.case_id, receipt.id)
    JOIN ductdelta.change_case AS item ON item.id = receipt.case_id
    JOIN ductdelta.project AS project ON project.id = receipt.project_id
    JOIN ductdelta.project_workflow_grant AS finance
      ON (finance.organization_id, finance.project_id) = (receipt.organization_id, receipt.project_id)
    WHERE receipt.organization_id = company_id
      AND (receipt.amount > receipt.allocated OR EXISTS (
          SELECT FROM ductdelta.case_allocation AS allocation
          WHERE allocation.case_id = destination_case AND allocation.receipt_id = receipt.id
      ))
      AND finance.actor_id = requesting_actor AND finance.capability = 'finance';
$$;

CREATE OR REPLACE FUNCTION ductdelta.case_totals(requested_case uuid)
RETURNS TABLE (
    proposed numeric, agreed numeric, unresolved numeric, unresolved_lines bigint,
    certified numeric, retained numeric, payable numeric, matched numeric,
    outstanding numeric, unallocated numeric, quote_awaiting_decision boolean
)
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH current_quote AS (
        SELECT id, data FROM ductdelta.case_event
        WHERE case_id = requested_case AND kind = 'quote'
        ORDER BY sequence DESC LIMIT 1
    ), effective_decision AS (
        -- Only a later decision replaces the currently agreed amounts.
        SELECT subject_id AS quote_id, data FROM ductdelta.case_event
        WHERE case_id = requested_case AND kind = 'decision'
        ORDER BY sequence DESC LIMIT 1
    ), proposal AS (
        SELECT sum(ductdelta.case_money(line, 'amount')) AS amount
        FROM current_quote CROSS JOIN LATERAL jsonb_array_elements(data -> 'lines') AS line
    ), agreement AS (
        SELECT sum(ductdelta.case_money(line, 'accepted')) AS amount,
            sum(CASE WHEN line ->> 'disposition' IN ('open', 'disputed')
                THEN ductdelta.case_money((quote.data -> 'lines') -> ((line ->> 'line')::int - 1), 'amount')
                     - ductdelta.case_money(line, 'accepted')
                ELSE 0.00 END) AS unresolved,
            count(*) FILTER (WHERE line ->> 'disposition' IN ('open', 'disputed')) AS unresolved_lines
        FROM effective_decision
        JOIN ductdelta.case_event AS quote ON quote.id = effective_decision.quote_id
        CROSS JOIN LATERAL jsonb_array_elements(effective_decision.data -> 'lines') AS line
    ), certification AS (
        SELECT coalesce(sum(work_delta), 0.00) AS certified,
            coalesce(sum(withheld - released), 0.00) AS retained,
            coalesce(sum(payable), 0.00) AS payable
        FROM ductdelta.case_certificate WHERE case_id = requested_case
    ), cash AS (
        SELECT coalesce(sum(amount - allocated), 0.00) AS unallocated
        FROM ductdelta.case_receipt WHERE case_id = requested_case
    ), allocation AS (
        SELECT coalesce(sum(amount), 0.00) AS matched
        FROM ductdelta.case_allocation WHERE case_id = requested_case
    )
    SELECT proposal.amount, agreement.amount, agreement.unresolved, agreement.unresolved_lines,
        certification.certified, certification.retained, certification.payable, allocation.matched,
        certification.payable - allocation.matched, cash.unallocated,
        EXISTS (
            SELECT FROM current_quote
            WHERE id IS DISTINCT FROM (SELECT quote_id FROM effective_decision)
        )
    FROM proposal CROSS JOIN agreement CROSS JOIN certification CROSS JOIN cash CROSS JOIN allocation;
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
       OR totals.retained <> 0 OR totals.outstanding <> 0 OR EXISTS (
        SELECT FROM ductdelta.case_receipt WHERE case_id = item.id AND NOT shared AND allocated <> amount
    ) THEN
        RAISE EXCEPTION 'Resolve open financial items before closing the case' USING ERRCODE = '23514';
    END IF;
    -- With cash within each signed payable's bounds, zero outstanding and
    -- zero available payable also imply that all certificate credits were used.
    IF EXISTS (
        SELECT FROM ductdelta.case_certificate_balances(item.id) AS balance
        JOIN ductdelta.case_certificate AS cert
            ON (cert.case_id, cert.id) = (item.id, balance.certificate_id)
        WHERE balance.available <> 0 OR balance.cash < 0 OR balance.cash > greatest(cert.payable, 0)
    ) THEN
        RAISE EXCEPTION 'Resolve each payable before closing the case' USING ERRCODE = '23514';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION ductdelta.case_ledger_action(
    item ductdelta.change_case, actor uuid, requested_operation uuid, action_kind text, payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    event_id uuid := gen_random_uuid();
    event_reference text;
    event_subject uuid;
    receipt_id uuid;
    receipt_case uuid;
    cert_id uuid;
    predecessor_id uuid;
    application_id uuid;
    latest_cert ductdelta.case_certificate;
    original_allocation ductdelta.case_allocation;
    amount numeric;
    work_delta numeric(18, 2);
    withheld numeric;
    released numeric;
    available numeric;
    line jsonb;
    financial_snapshot jsonb;
BEGIN
    IF item.agreement IS NULL AND action_kind <> 'close' THEN
        RAISE EXCEPTION 'Record the case agreement before posting commercial activity' USING ERRCODE = '23514';
    END IF;
    CASE action_kind
        WHEN 'quote' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['reference', 'lines']);
            event_reference := ductdelta.case_text(payload, 'reference', 160);
            IF jsonb_typeof(payload -> 'lines') IS DISTINCT FROM 'array'
               OR jsonb_array_length(payload -> 'lines') NOT BETWEEN 1 AND 99 THEN
                RAISE EXCEPTION 'A quote requires 1 to 99 priced lines' USING ERRCODE = '22023';
            END IF;
            FOR line IN SELECT value FROM jsonb_array_elements(payload -> 'lines') LOOP
                PERFORM ductdelta.case_fields(line, ARRAY['description', 'amount']);
                PERFORM ductdelta.case_text(line, 'description', 2000);
                PERFORM ductdelta.case_money(line, 'amount');
            END LOOP;
        WHEN 'decision' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['quote', 'lines', 'reason']);
            event_subject := ductdelta.case_text(payload, 'quote', 36)::uuid;
            PERFORM ductdelta.case_validate_decision(item.id, event_subject, payload);
        WHEN 'application' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['reference', 'amount']);
            event_reference := ductdelta.case_text(payload, 'reference', 160);
            PERFORM ductdelta.case_money(payload, 'amount');
        WHEN 'certificate' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY[
                'reference', 'cumulative', 'withheld', 'released', 'predecessor', 'application', 'reason'
            ]);
            event_reference := ductdelta.case_text(payload, 'reference', 160);
            amount := ductdelta.case_money(payload, 'cumulative');
            withheld := ductdelta.case_money(payload, 'withheld');
            released := ductdelta.case_money(payload, 'released');
            IF payload ? 'predecessor' THEN
                predecessor_id := ductdelta.case_text(payload, 'predecessor', 36)::uuid;
                PERFORM ductdelta.case_assert_event(item.id, predecessor_id, 'certificate');
            END IF;
            IF payload ? 'application' THEN
                application_id := ductdelta.case_text(payload, 'application', 36)::uuid;
                PERFORM ductdelta.case_assert_event(item.id, application_id, 'application');
            END IF;
            IF payload ? 'reason' THEN
                PERFORM ductdelta.case_text(payload, 'reason', 4000);
            END IF;
            SELECT cert.* INTO latest_cert
            FROM ductdelta.case_certificate AS cert
            JOIN ductdelta.case_event AS event ON event.id = cert.id
            WHERE cert.case_id = item.id ORDER BY event.sequence DESC LIMIT 1;
            IF predecessor_id IS DISTINCT FROM latest_cert.id THEN
                RAISE EXCEPTION 'Certificate must name the latest predecessor' USING ERRCODE = '23514';
            END IF;
            SELECT retained INTO available FROM ductdelta.case_totals(item.id);
            IF released < 0 OR withheld < 0 OR released > available OR (withheld > 0 AND released > 0)
               OR (released > 0 AND amount <> latest_cert.cumulative) THEN
                RAISE EXCEPTION 'Retention release must fit balance and leave work unchanged' USING ERRCODE = '23514';
            END IF;
            work_delta := amount - coalesce(latest_cert.cumulative, 0);
            financial_snapshot := jsonb_build_object(
                'work_delta', work_delta::text, 'payable', (work_delta - withheld + released)::text
            );
            event_subject := predecessor_id;
        WHEN 'receipt' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['reference', 'amount']);
            event_reference := ductdelta.case_text(payload, 'reference', 160);
            amount := ductdelta.case_money(payload, 'amount');
            IF amount <= 0 THEN
                RAISE EXCEPTION 'Receipt must be positive' USING ERRCODE = '23514';
            END IF;
        WHEN 'allocate' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['reference', 'receipt', 'certificate', 'amount']);
            event_reference := ductdelta.case_text(payload, 'reference', 160);
            receipt_id := ductdelta.case_text(payload, 'receipt', 36)::uuid;
            cert_id := ductdelta.case_text(payload, 'certificate', 36)::uuid;
            receipt_case := ductdelta.case_finance_receipt(item.organization_id, actor, receipt_id);
            PERFORM ductdelta.case_assert_event(item.id, cert_id, 'certificate');
            amount := ductdelta.case_money(payload, 'amount');
            IF amount <= 0 THEN
                RAISE EXCEPTION 'An allocation must be positive' USING ERRCODE = '23514';
            END IF;
            SELECT balance.available INTO STRICT available
            FROM ductdelta.case_certificate_balances(item.id) AS balance
            WHERE balance.certificate_id = cert_id;
            IF amount > available THEN
                RAISE EXCEPTION 'Allocation exceeds open payable' USING ERRCODE = '23514';
            END IF;
            PERFORM ductdelta.case_reserve_receipt(item.organization_id, receipt_id, item.id, amount);
            event_subject := CASE WHEN receipt_case = item.id THEN receipt_id ELSE cert_id END;
        WHEN 'reverse_allocation' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['allocation', 'reason']);
            PERFORM ductdelta.case_text(payload, 'reason', 4000);
            event_subject := ductdelta.case_text(payload, 'allocation', 36)::uuid;
            PERFORM ductdelta.case_assert_event(item.id, event_subject, 'allocate');
            IF EXISTS (
                SELECT FROM ductdelta.case_event
                WHERE (case_id, kind, subject_id) = (item.id, action_kind, event_subject)
            ) THEN
                RAISE EXCEPTION 'Allocation has already been reversed' USING ERRCODE = '23514';
            END IF;
            SELECT * INTO STRICT original_allocation FROM ductdelta.case_allocation
            WHERE (case_id, id) = (item.id, event_subject);
            amount := -original_allocation.amount;
            receipt_id := original_allocation.receipt_id;
            cert_id := original_allocation.certificate_id;
            PERFORM ductdelta.case_finance_receipt(item.organization_id, actor, receipt_id);
            PERFORM ductdelta.case_reserve_receipt(item.organization_id, receipt_id, item.id, amount);
        WHEN 'close' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['reason', 'outcome']);
            PERFORM ductdelta.case_text(payload, 'reason', 4000);
            PERFORM ductdelta.case_validate_close(item, ductdelta.case_text(payload, 'outcome', 12));
            financial_snapshot := ductdelta.case_financial(item.id, true) - 'unallocated';
            SELECT sum(credit_applied) INTO available
            FROM ductdelta.case_certificate_balances(item.id);
            IF available > 0 THEN
                financial_snapshot := financial_snapshot
                    || jsonb_build_object('certificate_credit_applied', available::text);
            END IF;
        ELSE RAISE EXCEPTION 'Unknown ledger action' USING ERRCODE = '22023';
    END CASE;

    INSERT INTO ductdelta.case_event (
        id, organization_id, project_id, case_id, actor_id, operation_id, kind, subject_id, reference, data, snapshot
    ) VALUES (
        event_id, item.organization_id, item.project_id, item.id, actor, requested_operation,
        action_kind, event_subject, event_reference, payload, financial_snapshot
    );

    CASE action_kind
        WHEN 'certificate' THEN
            INSERT INTO ductdelta.case_certificate (
                case_id, id, predecessor_id, application_id, cumulative, work_delta, withheld, released
            ) VALUES (
                item.id, event_id, predecessor_id, application_id, amount,
                work_delta, withheld, released
            );
        WHEN 'receipt' THEN
            INSERT INTO ductdelta.case_receipt (organization_id, project_id, case_id, id, amount)
            VALUES (item.organization_id, item.project_id, item.id, event_id, amount);
        WHEN 'allocate', 'reverse_allocation' THEN
            INSERT INTO ductdelta.case_allocation (
                organization_id, project_id, case_id, id, receipt_id, certificate_id, amount
            ) VALUES (item.organization_id, item.project_id, item.id, event_id, receipt_id, cert_id, amount);
            IF action_kind = 'reverse_allocation' AND item.closeout_id IS NOT NULL THEN
                UPDATE ductdelta.change_case SET closeout_id = NULL WHERE id = item.id;
            END IF;
        WHEN 'close' THEN
            UPDATE ductdelta.change_case SET closeout_id = event_id WHERE id = item.id;
        ELSE NULL;
    END CASE;
    RETURN jsonb_build_object('id', event_id);
END;
$$;

CREATE OR REPLACE FUNCTION ductdelta.web_case(
    session_digest bytea, requested_project uuid, requested_case uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, false);
    result jsonb;
BEGIN
    -- Read permissions, timeline and totals from the same statement snapshot.
    SELECT jsonb_build_object('id', item.id, 'title', item.title, 'closed', item.closeout_id IS NOT NULL,
        'observation_id', item.observation_id, 'agreement', item.agreement,
        'capabilities', access.capabilities,
        'events', ductdelta.case_timeline(item.id, access.financial, access.bank),
        'bank_receipts', CASE WHEN access.bank
            THEN ductdelta.case_bank_receipts(item.organization_id, member.actor_id, item.id)
            ELSE '[]'::jsonb END,
        'allocatable_certificates', CASE WHEN access.bank THEN (
            SELECT coalesce(jsonb_agg(certificate_id ORDER BY certificate_id), '[]'::jsonb)
            FROM ductdelta.case_certificate_balances(item.id) WHERE available > 0
        ) ELSE '[]'::jsonb END,
        'financial', CASE WHEN access.financial THEN ductdelta.case_financial(item.id, access.bank) END)
    INTO result
    FROM ductdelta.change_case AS item
    CROSS JOIN LATERAL (
        SELECT coalesce(jsonb_agg(capability ORDER BY capability), '[]'::jsonb) AS capabilities,
               count(*) FILTER (WHERE capability IN ('commercial', 'finance')) > 0 AS financial,
               count(*) FILTER (WHERE capability = 'finance') > 0 AS bank
        FROM ductdelta.project_workflow_grant
        WHERE (organization_id, project_id, actor_id) =
              (item.organization_id, item.project_id, member.actor_id)
    ) AS access
    WHERE (item.organization_id, item.project_id, item.id) =
          (member.organization_id, member.project_id, requested_case);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Case unavailable' USING ERRCODE = '42501';
    END IF;
    RETURN result;
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
    member ductdelta.project_member;
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

    IF action_kind IN ('allocate', 'reverse_allocation') THEN
        -- Access administration locks the company before its memberships.
        member := ductdelta.case_member(session_digest, requested_project, false);
        PERFORM FROM ductdelta.organization WHERE id = member.organization_id FOR KEY SHARE;
    END IF;
    member := ductdelta.case_member(session_digest, requested_project, true);

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

    -- Create a row version so an older snapshot cannot post against stale case balances.
    UPDATE ductdelta.change_case SET closeout_id = closeout_id
    WHERE (organization_id, project_id, id) = (member.organization_id, member.project_id, requested_case)
    RETURNING * INTO item;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Case unavailable' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO event FROM ductdelta.case_event
    WHERE (case_id, actor_id, operation_id) = (item.id, member.actor_id, requested_operation);
    IF FOUND THEN
        IF event.kind IN ('allocate', 'reverse_allocation') THEN
            PERFORM ductdelta.case_finance_receipt(item.organization_id, member.actor_id, receipt_id)
            FROM ductdelta.case_allocation WHERE (case_id, id) = (item.id, event.id);
        END IF;
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

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ductdelta FROM PUBLIC;

COMMIT;
