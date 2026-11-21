BEGIN;

SET LOCAL ROLE ductdelta_owner;

ALTER TABLE ductdelta.observation ADD UNIQUE (organization_id, project_id, id);

CREATE TABLE ductdelta.change_case (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    project_id uuid NOT NULL,
    actor_id uuid NOT NULL REFERENCES ductdelta.actor,
    operation_id uuid NOT NULL,
    observation_id uuid,
    title text NOT NULL,
    agreement text,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    closeout_id uuid,
    UNIQUE (organization_id, project_id, id),
    UNIQUE (organization_id, project_id, actor_id, operation_id),
    FOREIGN KEY (organization_id, project_id) REFERENCES ductdelta.project (organization_id, id),
    FOREIGN KEY (organization_id, project_id, observation_id)
        REFERENCES ductdelta.observation (organization_id, project_id, id)
);

CREATE INDEX change_case_project ON ductdelta.change_case
    (organization_id, project_id, recorded_at DESC, id DESC);

CREATE TABLE ductdelta.project_workflow_grant (
    organization_id uuid NOT NULL,
    project_id uuid NOT NULL,
    actor_id uuid NOT NULL,
    capability text NOT NULL CHECK (capability IN ('direction', 'commercial', 'finance')),
    PRIMARY KEY (organization_id, project_id, actor_id, capability),
    FOREIGN KEY (organization_id, project_id, actor_id)
        REFERENCES ductdelta.project_member (organization_id, project_id, actor_id) ON DELETE CASCADE
);

CREATE TABLE ductdelta.case_event (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sequence bigint GENERATED ALWAYS AS IDENTITY,
    organization_id uuid NOT NULL,
    project_id uuid NOT NULL,
    case_id uuid NOT NULL,
    actor_id uuid NOT NULL REFERENCES ductdelta.actor,
    operation_id uuid NOT NULL,
    kind text NOT NULL CHECK (kind IN (
        'notice', 'notice_dispatch', 'notice_receipt', 'instruction', 'work',
        'quote', 'decision', 'application', 'certificate', 'receipt', 'allocate',
        'reverse_allocation', 'close'
    )),
    subject_id uuid,
    reference text,
    data jsonb NOT NULL CHECK (jsonb_typeof(data) = 'object'),
    snapshot jsonb,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (case_id, id),
    UNIQUE (case_id, actor_id, operation_id),
    UNIQUE (case_id, kind, reference),
    FOREIGN KEY (organization_id, project_id, case_id)
        REFERENCES ductdelta.change_case (organization_id, project_id, id),
    FOREIGN KEY (case_id, subject_id) REFERENCES ductdelta.case_event (case_id, id)
);

ALTER TABLE ductdelta.change_case ADD FOREIGN KEY (id, closeout_id)
    REFERENCES ductdelta.case_event (case_id, id);
CREATE INDEX case_event_timeline ON ductdelta.case_event (case_id, sequence);

CREATE FUNCTION ductdelta.case_text(data jsonb, field text, max_chars integer) RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    result text := data ->> field;
BEGIN
    IF jsonb_typeof(data -> field) IS DISTINCT FROM 'string'
       OR char_length(result) > max_chars OR result !~ '[^[:space:]]' THEN
        RAISE EXCEPTION 'Missing or invalid %', field USING ERRCODE = '22023';
    END IF;
    RETURN result;
END;
$$;

CREATE FUNCTION ductdelta.case_fields(data jsonb, fields text[]) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF jsonb_typeof(data) IS DISTINCT FROM 'object' OR data - fields <> '{}'::jsonb THEN
        RAISE EXCEPTION 'Unexpected case action fields' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE FUNCTION ductdelta.case_member(session_digest bytea, requested_project uuid, write_access boolean)
RETURNS ductdelta.project_member
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member;
    actor uuid := ductdelta.web_actor(session_digest);
BEGIN
    IF write_access THEN
        SELECT * INTO member FROM ductdelta.project_member AS candidate
        WHERE candidate.project_id = requested_project AND candidate.actor_id = actor
        FOR SHARE;
    ELSE
        SELECT * INTO member FROM ductdelta.project_member AS candidate
        WHERE candidate.project_id = requested_project AND candidate.actor_id = actor;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Project unavailable' USING ERRCODE = '42501';
    END IF;
    RETURN member;
END;
$$;

CREATE FUNCTION ductdelta.web_cases(
    session_digest bytea, requested_project uuid, before_case uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, false);
    cursor_time timestamptz;
    result jsonb;
BEGIN
    IF before_case IS NOT NULL THEN
        SELECT recorded_at INTO cursor_time
        FROM ductdelta.change_case
        WHERE (organization_id, project_id, id) =
              (member.organization_id, member.project_id, before_case);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Case cursor unavailable' USING ERRCODE = '42501';
        END IF;
    END IF;

    WITH page AS (
        SELECT id, title, closeout_id, recorded_at
        FROM ductdelta.change_case
        WHERE (organization_id, project_id) = (member.organization_id, member.project_id)
          AND (before_case IS NULL OR (recorded_at, id) < (cursor_time, before_case))
        ORDER BY recorded_at DESC, id DESC
        LIMIT 101
    ), visible AS (
        SELECT * FROM page ORDER BY recorded_at DESC, id DESC LIMIT 100
    )
    SELECT jsonb_build_object(
        'cases', coalesce(jsonb_agg(jsonb_build_object(
            'id', id, 'title', title, 'closed', closeout_id IS NOT NULL
        ) ORDER BY recorded_at DESC, id DESC), '[]'::jsonb),
        'next_before', CASE WHEN (SELECT count(*) FROM page) > 100
                       THEN (SELECT id FROM visible ORDER BY recorded_at, id LIMIT 1) END
    )
    INTO result
    FROM visible;
    RETURN result;
END;
$$;

CREATE FUNCTION ductdelta.web_create_case(
    session_digest bytea, requested_project uuid, requested_operation uuid,
    requested_title text, requested_observation uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, true);
    saved ductdelta.change_case;
BEGIN
    IF member.permission <> 'capture' THEN
        RAISE EXCEPTION 'Capture permission required' USING ERRCODE = '42501';
    END IF;
    IF requested_operation IS NULL THEN
        RAISE EXCEPTION 'Operation required' USING ERRCODE = '22023';
    END IF;
    PERFORM ductdelta.case_text(jsonb_build_object('title', requested_title), 'title', 160);
    IF requested_observation IS NOT NULL AND NOT EXISTS (
        SELECT FROM ductdelta.observation AS source
        WHERE (source.organization_id, source.project_id, source.id) =
              (member.organization_id, member.project_id, requested_observation)
    ) THEN
        RAISE EXCEPTION 'Observation unavailable' USING ERRCODE = '42501';
    END IF;

    INSERT INTO ductdelta.change_case (
        organization_id, project_id, actor_id, operation_id, title, observation_id
    ) VALUES (
        member.organization_id, member.project_id, member.actor_id, requested_operation,
        requested_title, requested_observation
    )
    ON CONFLICT (organization_id, project_id, actor_id, operation_id) DO NOTHING
    RETURNING * INTO saved;

    IF NOT FOUND THEN
        SELECT * INTO STRICT saved
        FROM ductdelta.change_case
        WHERE (organization_id, project_id, actor_id, operation_id) =
              (member.organization_id, member.project_id, member.actor_id, requested_operation);
        IF (saved.title, saved.observation_id) IS DISTINCT FROM (requested_title, requested_observation) THEN
            RAISE EXCEPTION 'Operation ID already records a different case' USING ERRCODE = 'DD001';
        END IF;
    END IF;
    RETURN jsonb_build_object('id', saved.id);
END;
$$;

CREATE FUNCTION ductdelta.case_timeline(
    requested_case uuid, financial_access boolean, bank_access boolean
) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', event.id, 'kind', event.kind, 'recorded_at', event.recorded_at,
        'actor_id', event.actor_id, 'data', CASE
            WHEN financial_access AND event.snapshot IS NOT NULL
                THEN event.data || jsonb_build_object('financial_snapshot', event.snapshot)
            ELSE event.data END
    ) ORDER BY event.sequence), '[]'::jsonb)
    FROM ductdelta.case_event AS event
    WHERE event.case_id = requested_case
      AND (financial_access OR event.kind IN ('notice', 'notice_dispatch', 'notice_receipt', 'instruction', 'work', 'close'))
      AND (bank_access OR event.kind NOT IN ('receipt', 'allocate', 'reverse_allocation'));
$$;

CREATE FUNCTION ductdelta.web_case(
    session_digest bytea, requested_project uuid, requested_case uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, false);
    item ductdelta.change_case;
BEGIN
    SELECT * INTO item FROM ductdelta.change_case
    WHERE (organization_id, project_id, id) = (member.organization_id, member.project_id, requested_case);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Case unavailable' USING ERRCODE = '42501';
    END IF;
    RETURN jsonb_build_object('id', item.id, 'title', item.title, 'closed', item.closeout_id IS NOT NULL,
        'observation_id', item.observation_id, 'agreement', item.agreement,
        'events', ductdelta.case_timeline(item.id, false, false), 'financial', NULL);
END;
$$;

CREATE FUNCTION ductdelta.case_assert_event(requested_case uuid, requested_event uuid, expected_kind text)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT FROM ductdelta.case_event
        WHERE (case_id, id, kind) = (requested_case, requested_event, expected_kind)
    ) THEN
        RAISE EXCEPTION 'Referenced event unavailable' USING ERRCODE = '42501';
    END IF;
END;
$$;

CREATE FUNCTION ductdelta.web_case_action(
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
        WHEN 'quote', 'decision', 'application', 'close' THEN capability_needed := 'commercial';
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
    IF item.closeout_id IS NOT NULL AND action_kind <> 'reverse_allocation' THEN
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
    RETURN jsonb_build_object('id', event.id);
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ductdelta FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.web_cases(bytea, uuid, uuid),
    ductdelta.web_create_case(bytea, uuid, uuid, text, uuid),
    ductdelta.web_case(bytea, uuid, uuid),
    ductdelta.web_case_action(bytea, uuid, uuid, uuid, text, jsonb)
    TO ductdelta_web_runtime;

COMMIT;
