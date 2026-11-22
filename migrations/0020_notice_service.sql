BEGIN;

SET LOCAL ROLE ductdelta_owner;

ALTER FUNCTION ductdelta.web_case_action(bytea, uuid, uuid, uuid, text, jsonb)
    RENAME TO record_other_service_case_action;
REVOKE EXECUTE ON FUNCTION ductdelta.record_other_service_case_action(bytea, uuid, uuid, uuid, text, jsonb)
    FROM ductdelta_web_runtime;

CREATE FUNCTION ductdelta.web_case_action(
    session_digest bytea, requested_project uuid, requested_case uuid, requested_operation uuid,
    action_kind text, payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member;
    item ductdelta.change_case;
    event ductdelta.case_event;
    notice ductdelta.case_event;
    dispatch ductdelta.case_event;
    issued ductdelta.issued_notice_copy;
    recorded_data jsonb := payload;
    source_notice_id uuid;
    dispatch_id uuid;
    event_reference text;
    expected_method text;
    actual_method text;
    has_copies boolean;
BEGIN
    IF action_kind IS NULL OR action_kind NOT IN ('notice_dispatch', 'notice_receipt') THEN
        RETURN ductdelta.record_other_service_case_action(
            session_digest, requested_project, requested_case, requested_operation, action_kind, payload
        );
    END IF;

    IF requested_operation IS NULL OR jsonb_typeof(payload) IS DISTINCT FROM 'object'
       OR octet_length(payload::text) > 65536 THEN
        RAISE EXCEPTION 'Invalid notice service action' USING ERRCODE = '22023';
    END IF;
    member := ductdelta.case_member(session_digest, requested_project, true);
    PERFORM FROM ductdelta.project_workflow_grant
    WHERE (organization_id, project_id, actor_id, capability) =
          (member.organization_id, member.project_id, member.actor_id, 'direction')
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Notice service requires the direction grant' USING ERRCODE = '42501';
    END IF;

    -- Serialize with issuance and closeout on the same case row.
    UPDATE ductdelta.change_case SET closeout_id = closeout_id
    WHERE (organization_id, project_id, id) = (member.organization_id, member.project_id, requested_case)
    RETURNING * INTO item;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Case unavailable' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO event FROM ductdelta.case_event
    WHERE (case_id, actor_id, operation_id) = (item.id, member.actor_id, requested_operation);
    IF FOUND THEN
        IF (event.kind, event.data - 'copy') IS DISTINCT FROM (action_kind, payload) THEN
            RAISE EXCEPTION 'Operation ID already records a different action' USING ERRCODE = 'DD001';
        END IF;
        RETURN jsonb_build_object('id', event.id);
    END IF;
    IF item.closeout_id IS NOT NULL THEN
        RAISE EXCEPTION 'Case is closed' USING ERRCODE = '23514';
    END IF;

    source_notice_id := ductdelta.case_text(payload, 'notice', 36)::uuid;
    event_reference := ductdelta.case_text(payload, 'reference', 160);
    SELECT * INTO notice FROM ductdelta.case_event
    WHERE (case_id, id, kind) = (item.id, source_notice_id, 'notice');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Notice unavailable' USING ERRCODE = '42501';
    END IF;
    SELECT EXISTS (SELECT FROM ductdelta.issued_notice_copy WHERE notice_id = notice.id) INTO has_copies;

    IF action_kind = 'notice_dispatch' THEN
        IF payload ? 'issued_copy' THEN
            PERFORM ductdelta.case_fields(payload, ARRAY[
                'notice', 'reference', 'issued_copy', 'recipient', 'service_method', 'service_evidence', 'corrects_dispatch'
            ]);
            SELECT * INTO issued FROM ductdelta.issued_notice_copy
            WHERE (case_id, notice_id, id) =
                  (item.id, notice.id, ductdelta.case_text(payload, 'issued_copy', 36)::uuid);
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Issued copy unavailable' USING ERRCODE = '42501';
            END IF;
            IF ductdelta.case_text(payload, 'recipient', 250) <> issued.recipient THEN
                RAISE EXCEPTION 'Select the issued copy for the actual recipient' USING ERRCODE = '22023';
            END IF;
            expected_method := notice.data -> 'notice_rule' ->> 'service_method';
            actual_method := ductdelta.case_text(payload, 'service_method', 240);
            IF payload ? 'service_evidence' THEN
                PERFORM ductdelta.case_text(payload, 'service_evidence', 2000);
            ELSIF expected_method IS NOT NULL AND actual_method <> expected_method THEN
                RAISE EXCEPTION 'Document the alternative service method' USING ERRCODE = '22023';
            END IF;
            IF payload ? 'corrects_dispatch' THEN
                dispatch_id := ductdelta.case_text(payload, 'corrects_dispatch', 36)::uuid;
                PERFORM FROM ductdelta.case_event
                WHERE (case_id, subject_id, kind, id) = (item.id, notice.id, 'notice_dispatch', dispatch_id);
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'Dispatch to correct unavailable' USING ERRCODE = '42501';
                END IF;
            END IF;
            recorded_data := payload || jsonb_build_object('copy', jsonb_build_object(
                'id', issued.id, 'version', issued.version, 'recipient', issued.recipient,
                'sha256', encode(issued.sha256, 'hex')
            ));
        ELSE
            PERFORM ductdelta.case_fields(payload, ARRAY['notice', 'reference']);
            IF has_copies THEN
                RAISE EXCEPTION 'Select the exact issued copy that was dispatched' USING ERRCODE = '23514';
            END IF;
        END IF;
    ELSE
        PERFORM ductdelta.case_fields(payload, ARRAY['notice', 'reference', 'dispatch']);
        IF payload ? 'dispatch' THEN
            dispatch_id := ductdelta.case_text(payload, 'dispatch', 36)::uuid;
            SELECT * INTO dispatch FROM ductdelta.case_event
            WHERE (case_id, subject_id, kind, id) = (item.id, notice.id, 'notice_dispatch', dispatch_id);
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Dispatch unavailable' USING ERRCODE = '42501';
            END IF;
            IF dispatch.data ? 'copy' THEN
                recorded_data := payload || jsonb_build_object('copy', dispatch.data -> 'copy');
            END IF;
        ELSIF has_copies OR NOT EXISTS (
            SELECT FROM ductdelta.case_event WHERE (case_id, kind, subject_id) = (item.id, 'notice_dispatch', notice.id)
        ) THEN
            RAISE EXCEPTION 'Record and select the dispatch before acknowledgement' USING ERRCODE = '23514';
        END IF;
    END IF;

    INSERT INTO ductdelta.case_event (
        organization_id, project_id, case_id, actor_id, operation_id, kind, subject_id, reference, data
    ) VALUES (
        item.organization_id, item.project_id, item.id, member.actor_id, requested_operation,
        action_kind, notice.id, event_reference, recorded_data
    ) RETURNING * INTO event;
    RETURN jsonb_build_object('id', event.id);
END;
$$;

ALTER FUNCTION ductdelta.web_case(bytea, uuid, uuid) RENAME TO read_case_without_issued_copies;
REVOKE EXECUTE ON FUNCTION ductdelta.read_case_without_issued_copies(bytea, uuid, uuid) FROM ductdelta_web_runtime;

CREATE FUNCTION ductdelta.web_case(session_digest bytea, requested_project uuid, requested_case uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    result jsonb := ductdelta.read_case_without_issued_copies(session_digest, requested_project, requested_case);
BEGIN
    RETURN result || jsonb_build_object('issued_notice_copies', (
        SELECT coalesce(jsonb_agg(ductdelta.issued_notice_metadata(copy) ||
            jsonb_build_object('notice_id', copy.notice_id) ORDER BY copy.issued_at DESC, copy.version DESC), '[]'::jsonb)
        FROM ductdelta.issued_notice_copy AS copy WHERE copy.case_id = requested_case
    ));
END;
$$;

REVOKE ALL ON FUNCTION ductdelta.web_case_action(bytea, uuid, uuid, uuid, text, jsonb),
    ductdelta.web_case(bytea, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.web_case_action(bytea, uuid, uuid, uuid, text, jsonb),
    ductdelta.web_case(bytea, uuid, uuid) TO ductdelta_web_runtime;

COMMIT;
