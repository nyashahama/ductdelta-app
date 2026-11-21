BEGIN;

SET LOCAL ROLE ductdelta_owner;

-- A bank statement reference identifies one receipt in the owning organization.
CREATE UNIQUE INDEX case_event_receipt_reference ON ductdelta.case_event (organization_id, reference)
    WHERE kind = 'receipt';
CREATE UNIQUE INDEX case_event_allocation_reversal ON ductdelta.case_event (case_id, subject_id)
    WHERE kind = 'reverse_allocation';

CREATE TABLE ductdelta.case_certificate (
    case_id uuid NOT NULL,
    id uuid NOT NULL,
    predecessor_id uuid,
    application_id uuid,
    cumulative numeric(18, 2) NOT NULL,
    work_delta numeric(18, 2) NOT NULL,
    withheld numeric(18, 2) NOT NULL CHECK (withheld >= 0),
    released numeric(18, 2) NOT NULL CHECK (released >= 0),
    payable numeric(18, 2) GENERATED ALWAYS AS (work_delta - withheld + released) STORED,
    PRIMARY KEY (case_id, id),
    UNIQUE NULLS NOT DISTINCT (case_id, predecessor_id),
    FOREIGN KEY (case_id, id) REFERENCES ductdelta.case_event (case_id, id),
    FOREIGN KEY (case_id, predecessor_id) REFERENCES ductdelta.case_certificate (case_id, id),
    FOREIGN KEY (case_id, application_id) REFERENCES ductdelta.case_event (case_id, id)
);

CREATE TABLE ductdelta.case_receipt (
    case_id uuid NOT NULL,
    id uuid NOT NULL,
    amount numeric(18, 2) NOT NULL CHECK (amount > 0),
    PRIMARY KEY (case_id, id),
    FOREIGN KEY (case_id, id) REFERENCES ductdelta.case_event (case_id, id)
);

CREATE TABLE ductdelta.case_allocation (
    case_id uuid NOT NULL,
    id uuid NOT NULL,
    receipt_id uuid NOT NULL,
    certificate_id uuid NOT NULL,
    amount numeric(18, 2) NOT NULL CHECK (amount <> 0),
    PRIMARY KEY (case_id, id),
    FOREIGN KEY (case_id, id) REFERENCES ductdelta.case_event (case_id, id),
    FOREIGN KEY (case_id, receipt_id) REFERENCES ductdelta.case_receipt (case_id, id),
    FOREIGN KEY (case_id, certificate_id) REFERENCES ductdelta.case_certificate (case_id, id)
);

CREATE INDEX case_allocation_receipt ON ductdelta.case_allocation (case_id, receipt_id);
CREATE INDEX case_allocation_certificate ON ductdelta.case_allocation (case_id, certificate_id);

CREATE FUNCTION ductdelta.case_money(data jsonb, field text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    value text := ductdelta.case_text(data, field, 16);
BEGIN
    IF value !~ '^-?(0|[1-9][0-9]{0,11})([.][0-9]{1,2})?$' THEN
        RAISE EXCEPTION 'Invalid decimal amount for %', field USING ERRCODE = '22023';
    END IF;
    RETURN value::numeric(18, 2);
END;
$$;

CREATE FUNCTION ductdelta.case_totals(requested_case uuid)
RETURNS TABLE (
    proposed numeric, agreed numeric, unresolved numeric, unresolved_lines bigint,
    certified numeric, retained numeric, payable numeric, matched numeric,
    outstanding numeric, unallocated numeric
)
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH current_quote AS (
        SELECT id, data FROM ductdelta.case_event
        WHERE case_id = requested_case AND kind = 'quote'
        ORDER BY sequence DESC LIMIT 1
    ), current_decision AS (
        SELECT decision.data
        FROM ductdelta.case_event AS decision JOIN current_quote AS quote ON quote.id = decision.subject_id
        WHERE decision.case_id = requested_case AND decision.kind = 'decision'
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
        FROM current_decision
        CROSS JOIN LATERAL jsonb_array_elements(current_decision.data -> 'lines') AS line
        CROSS JOIN current_quote AS quote
    ), certification AS (
        SELECT coalesce(sum(work_delta), 0.00) AS certified,
            coalesce(sum(withheld - released), 0.00) AS retained,
            coalesce(sum(payable), 0.00) AS payable
        FROM ductdelta.case_certificate WHERE case_id = requested_case
    ), cash AS (
        SELECT coalesce(sum(amount), 0.00) AS received
        FROM ductdelta.case_receipt WHERE case_id = requested_case
    ), allocation AS (
        SELECT coalesce(sum(amount), 0.00) AS matched
        FROM ductdelta.case_allocation WHERE case_id = requested_case
    )
    SELECT proposal.amount, agreement.amount, agreement.unresolved, agreement.unresolved_lines,
        certification.certified, certification.retained, certification.payable, allocation.matched,
        certification.payable - allocation.matched, cash.received - allocation.matched
    FROM proposal CROSS JOIN agreement CROSS JOIN certification CROSS JOIN cash CROSS JOIN allocation;
$$;

CREATE FUNCTION ductdelta.case_financial(requested_case uuid, bank_access boolean) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'currency', 'ZAR', 'basis', 'excl_vat',
        'proposed', proposed::text, 'agreed', agreed::text, 'unresolved', unresolved::text,
        'certified', certified::text, 'retained', retained::text, 'payable', payable::text,
        'matched', matched::text, 'outstanding', outstanding::text,
        'unallocated', CASE WHEN bank_access THEN unallocated::text END
    )
    FROM ductdelta.case_totals(requested_case);
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

CREATE FUNCTION ductdelta.case_validate_decision(requested_case uuid, quote_id uuid, decision jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    quote_lines jsonb;
    line jsonb;
    disposition text;
    line_no integer;
    seen integer[] := ARRAY[]::integer[];
    proposed_amount numeric;
    accepted_amount numeric;
BEGIN
    PERFORM ductdelta.case_text(decision, 'reason', 4000);
    SELECT data -> 'lines' INTO quote_lines
    FROM ductdelta.case_event WHERE case_id = requested_case AND kind = 'quote'
    ORDER BY sequence DESC LIMIT 1;
    IF NOT FOUND OR NOT EXISTS (
        SELECT FROM ductdelta.case_event WHERE case_id = requested_case AND kind = 'quote' AND id = quote_id
          AND sequence = (SELECT max(sequence) FROM ductdelta.case_event
                          WHERE case_id = requested_case AND kind = 'quote')
    ) THEN
        RAISE EXCEPTION 'Decision requires the current quote' USING ERRCODE = '23514';
    END IF;
    IF jsonb_typeof(decision -> 'lines') IS DISTINCT FROM 'array'
       OR jsonb_array_length(decision -> 'lines') <> jsonb_array_length(quote_lines) THEN
        RAISE EXCEPTION 'Decide every quote line exactly once' USING ERRCODE = '22023';
    END IF;

    FOR line IN SELECT value FROM jsonb_array_elements(decision -> 'lines') LOOP
        PERFORM ductdelta.case_fields(line, ARRAY['line', 'accepted', 'disposition']);
        IF jsonb_typeof(line -> 'line') IS DISTINCT FROM 'number' OR (line ->> 'line') !~ '^[1-9][0-9]?$' THEN
            RAISE EXCEPTION 'Invalid quote line number' USING ERRCODE = '22023';
        END IF;
        line_no := (line ->> 'line')::integer;
        IF line_no > jsonb_array_length(quote_lines) OR line_no = ANY (seen) THEN
            RAISE EXCEPTION 'Decide every quote line exactly once' USING ERRCODE = '22023';
        END IF;
        seen := array_append(seen, line_no);
        disposition := ductdelta.case_text(line, 'disposition', 12);
        accepted_amount := ductdelta.case_money(line, 'accepted');
        proposed_amount := ductdelta.case_money(quote_lines -> (line_no - 1), 'amount');
        IF disposition NOT IN ('open', 'disputed', 'waived', 'accepted')
           OR (disposition = 'accepted') <> (accepted_amount = proposed_amount)
           OR accepted_amount NOT BETWEEN least(0, proposed_amount) AND greatest(0, proposed_amount) THEN
            RAISE EXCEPTION 'Decision amounts must fit the signed quote line and disposition' USING ERRCODE = '23514';
        END IF;
    END LOOP;
END;
$$;

CREATE FUNCTION ductdelta.case_validate_close(item ductdelta.change_case, outcome text) RETURNS void
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
        SELECT (data ->> 'completed')::boolean AND subject_id IS NOT NULL
        FROM ductdelta.case_event WHERE case_id = item.id AND kind = 'work'
        ORDER BY sequence DESC LIMIT 1
    ), false) THEN
        RAISE EXCEPTION 'Record completed work and its direction' USING ERRCODE = '23514';
    END IF;
    IF totals.agreed IS NULL OR totals.unresolved_lines > 0 OR totals.agreed <> totals.certified
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

CREATE FUNCTION ductdelta.case_ledger_action(
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
            PERFORM ductdelta.case_assert_event(item.id, receipt_id, 'receipt');
            PERFORM ductdelta.case_assert_event(item.id, cert_id, 'certificate');
            amount := ductdelta.case_money(payload, 'amount');
            IF amount <= 0 THEN
                RAISE EXCEPTION 'An allocation must be positive' USING ERRCODE = '23514';
            END IF;
            SELECT receipt.amount - coalesce((
                SELECT sum(allocation.amount) FROM ductdelta.case_allocation AS allocation
                WHERE (allocation.case_id, allocation.receipt_id) = (item.id, receipt.id)
            ), 0) INTO available
            FROM ductdelta.case_receipt AS receipt WHERE (receipt.case_id, receipt.id) = (item.id, receipt_id);
            IF amount > available THEN
                RAISE EXCEPTION 'Allocation exceeds available receipt' USING ERRCODE = '23514';
            END IF;
            SELECT cert.payable - coalesce((
                SELECT sum(allocation.amount) FROM ductdelta.case_allocation AS allocation
                WHERE (allocation.case_id, allocation.certificate_id) = (item.id, cert.id)
            ), 0) INTO available
            FROM ductdelta.case_certificate AS cert WHERE (cert.case_id, cert.id) = (item.id, cert_id);
            IF amount > available THEN
                RAISE EXCEPTION 'Allocation exceeds open payable' USING ERRCODE = '23514';
            END IF;
            event_subject := receipt_id;
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
        WHEN 'close' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY['reason', 'outcome']);
            PERFORM ductdelta.case_text(payload, 'reason', 4000);
            PERFORM ductdelta.case_validate_close(item, ductdelta.case_text(payload, 'outcome', 12));
            financial_snapshot := ductdelta.case_financial(item.id, true) - 'unallocated';
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
            INSERT INTO ductdelta.case_receipt (case_id, id, amount) VALUES (item.id, event_id, amount);
        WHEN 'allocate', 'reverse_allocation' THEN
            INSERT INTO ductdelta.case_allocation (case_id, id, receipt_id, certificate_id, amount)
            VALUES (item.id, event_id, receipt_id, cert_id, amount);
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

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ductdelta FROM PUBLIC;

COMMIT;
