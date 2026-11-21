BEGIN;

SET LOCAL ROLE ductdelta_owner;

-- Apply signed certificate credits after cash, oldest unpaid certificate first.
-- Recompute from the ledger so reversals preserve the original cash and certificate records.
CREATE FUNCTION ductdelta.case_certificate_balances(requested_case uuid)
RETURNS TABLE (certificate_id uuid, cash numeric, credit_applied numeric, available numeric)
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH matched AS (
        SELECT certificate_id, sum(amount) AS cash
        FROM ductdelta.case_allocation
        WHERE case_id = requested_case
        GROUP BY certificate_id
    ), balances AS (
        SELECT cert.id AS certificate_id, event.sequence,
            coalesce(matched.cash, 0.00) AS cash,
            greatest(cert.payable - coalesce(matched.cash, 0.00), 0.00) AS unpaid,
            greatest(-cert.payable, 0.00) AS credit
        FROM ductdelta.case_certificate AS cert
        JOIN ductdelta.case_event AS event ON (event.case_id, event.id) = (cert.case_id, cert.id)
        LEFT JOIN matched ON matched.certificate_id = cert.id
        WHERE cert.case_id = requested_case
    ), offsets AS (
        SELECT certificate_id, cash, unpaid, least(unpaid, greatest(
            sum(credit) OVER () - coalesce(sum(unpaid) OVER (
                ORDER BY sequence ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ), 0.00), 0.00
        )) AS credit_applied
        FROM balances
    )
    SELECT certificate_id, cash, credit_applied, unpaid - credit_applied AS available
    FROM offsets;
$$;

REVOKE ALL ON FUNCTION ductdelta.case_certificate_balances(uuid) FROM PUBLIC;

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
            SELECT balance.available INTO STRICT available
            FROM ductdelta.case_certificate_balances(item.id) AS balance
            WHERE balance.certificate_id = cert_id;
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

COMMIT;
