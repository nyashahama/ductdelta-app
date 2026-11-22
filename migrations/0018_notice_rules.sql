BEGIN;

SET LOCAL ROLE ductdelta_owner;

CREATE TABLE ductdelta.project_notice_rule (
    organization_id uuid NOT NULL,
    project_id uuid NOT NULL,
    version integer NOT NULL CHECK (version > 0),
    actor_id uuid NOT NULL REFERENCES ductdelta.actor,
    operation_id uuid NOT NULL,
    details jsonb NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (organization_id, project_id, version),
    UNIQUE (organization_id, project_id, actor_id, operation_id),
    FOREIGN KEY (organization_id, project_id) REFERENCES ductdelta.project (organization_id, id)
);

ALTER TABLE ductdelta.case_event ADD COLUMN notice_input jsonb
    CHECK (notice_input IS NULL OR (kind = 'notice' AND jsonb_typeof(notice_input) = 'object'));

CREATE FUNCTION ductdelta.current_notice_rule(company uuid, project uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp
AS $$
    SELECT details FROM ductdelta.project_notice_rule
    WHERE (organization_id, project_id) = (company, project)
    ORDER BY version DESC LIMIT 1;
$$;

CREATE FUNCTION ductdelta.web_project_notice_rule(session_digest bytea, requested_project uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, false);
    can_manage boolean;
    issuers jsonb := '[]'::jsonb;
BEGIN
    SELECT EXISTS (
        SELECT FROM ductdelta.organization_member
        WHERE (organization_id, actor_id, role) = (member.organization_id, member.actor_id, 'admin')
    ) INTO can_manage;
    IF can_manage THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('id', candidate.actor_id, 'name', account.display_name)
                                  ORDER BY account.display_name, candidate.actor_id), '[]'::jsonb)
        INTO issuers
        FROM ductdelta.project_workflow_grant AS candidate
        JOIN ductdelta.web_access_key AS account ON account.actor_id = candidate.actor_id
        WHERE (candidate.organization_id, candidate.project_id, candidate.capability) =
              (member.organization_id, member.project_id, 'direction');
    END IF;
    RETURN jsonb_build_object(
        'actor_id', member.actor_id, 'can_manage', can_manage, 'issuers', issuers,
        'rule', ductdelta.current_notice_rule(member.organization_id, member.project_id)
    );
END;
$$;

CREATE FUNCTION ductdelta.web_publish_notice_rule(
    session_digest bytea, requested_project uuid, requested_operation uuid,
    expected_version integer, payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, false);
    saved ductdelta.project_notice_rule;
    active_rule jsonb;
    deadline_mode text;
    timezone_name text;
    window_size text;
    issuer uuid;
    issuer_name text;
BEGIN
    PERFORM ductdelta.lock_company_admin(session_digest, member.organization_id);
    -- Both publishing and recording lock the project before reading the active rule.
    -- A new project row version forces an older transaction snapshot to retry.
    UPDATE ductdelta.project SET name = name
    WHERE (organization_id, id) = (member.organization_id, member.project_id);
    member := ductdelta.case_member(session_digest, requested_project, true);

    SELECT * INTO saved FROM ductdelta.project_notice_rule
    WHERE (organization_id, project_id, actor_id, operation_id) =
          (member.organization_id, member.project_id, member.actor_id, requested_operation);
    IF FOUND THEN
        IF (saved.version - 1, saved.details - ARRAY['version', 'issuer_name'])
            IS DISTINCT FROM (expected_version, payload) THEN
            RAISE EXCEPTION 'Operation already published a different rule' USING ERRCODE = 'DD001';
        END IF;
        RETURN saved.details;
    END IF;
    active_rule := ductdelta.current_notice_rule(member.organization_id, member.project_id);
    IF expected_version IS DISTINCT FROM coalesce((active_rule ->> 'version')::integer, 0) THEN
        RAISE EXCEPTION 'Notice rule version changed' USING ERRCODE = 'DD005';
    END IF;
    IF requested_operation IS NULL THEN
        RAISE EXCEPTION 'Operation required' USING ERRCODE = '22023';
    END IF;
    PERFORM ductdelta.case_fields(payload, ARRAY[
        'agreement', 'clause', 'issuer_actor_id', 'authority', 'recipient', 'service_method',
        'timezone', 'deadline_mode', 'window', 'trigger', 'manual_instructions'
    ]);
    PERFORM ductdelta.case_text(payload, 'agreement', 160);
    PERFORM ductdelta.case_text(payload, 'clause', 160);
    PERFORM ductdelta.case_text(payload, 'authority', 160);
    PERFORM ductdelta.case_text(payload, 'recipient', 240);
    PERFORM ductdelta.case_text(payload, 'service_method', 240);
    PERFORM ductdelta.case_text(payload, 'trigger', 240);
    IF EXISTS (
        SELECT FROM jsonb_each_text(payload - 'manual_instructions')
        WHERE value ~ '[[:cntrl:]]'
    ) THEN
        RAISE EXCEPTION 'Use one line for notice rule fields' USING ERRCODE = '22023';
    END IF;
    timezone_name := ductdelta.case_text(payload, 'timezone', 100);
    IF (timezone_name <> 'UTC' AND position('/' in timezone_name) = 0)
        OR NOT EXISTS (SELECT FROM pg_timezone_names WHERE name = timezone_name) THEN
        RAISE EXCEPTION 'Invalid contract time zone' USING ERRCODE = '22023';
    END IF;

    deadline_mode := ductdelta.case_text(payload, 'deadline_mode', 20);
    CASE deadline_mode
        WHEN 'manual' THEN
            IF payload ? 'window' THEN
                RAISE EXCEPTION 'Manual deadlines have no automatic window' USING ERRCODE = '22023';
            END IF;
            PERFORM ductdelta.case_text(payload, 'manual_instructions', 4000);
        WHEN 'elapsed_hours', 'calendar_days' THEN
            window_size := payload ->> 'window';
            IF jsonb_typeof(payload -> 'window') IS DISTINCT FROM 'number'
                OR window_size !~ '^[1-9][0-9]{0,2}$'
                OR payload ? 'manual_instructions' THEN
                RAISE EXCEPTION 'Enter a whole window from 1 to 999' USING ERRCODE = '22023';
            END IF;
        ELSE
            RAISE EXCEPTION 'Invalid deadline mechanism' USING ERRCODE = '22023';
    END CASE;

    issuer := ductdelta.case_text(payload, 'issuer_actor_id', 36)::uuid;
    SELECT account.display_name INTO issuer_name
    FROM ductdelta.project_workflow_grant AS candidate
    JOIN ductdelta.web_access_key AS account ON account.actor_id = candidate.actor_id
    WHERE (candidate.organization_id, candidate.project_id, candidate.actor_id, candidate.capability) =
          (member.organization_id, member.project_id, issuer, 'direction')
    FOR SHARE OF candidate;
    IF NOT FOUND OR issuer_name ~ '[[:cntrl:]]' OR issuer::text <> payload ->> 'issuer_actor_id' THEN
        RAISE EXCEPTION 'Choose an assigned issuer with direction access' USING ERRCODE = '22023';
    END IF;

    INSERT INTO ductdelta.project_notice_rule (
        organization_id, project_id, version, actor_id, operation_id, details
    ) VALUES (
        member.organization_id, member.project_id, expected_version + 1, member.actor_id, requested_operation,
        payload || jsonb_build_object('version', expected_version + 1, 'issuer_name', issuer_name)
    ) RETURNING * INTO saved;
    RETURN saved.details;
END;
$$;

CREATE FUNCTION ductdelta.notice_time(payload jsonb, field text) RETURNS timestamptz
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    value text := ductdelta.case_text(payload, field, 40);
BEGIN
    IF value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([.][0-9]{1,6})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$' THEN
        RAISE EXCEPTION '% requires a date, time and offset', field USING ERRCODE = '22023';
    END IF;
    RETURN value::timestamptz;
END;
$$;

CREATE FUNCTION ductdelta.record_project_notice(
    session_digest bytea, requested_project uuid, requested_case uuid,
    requested_operation uuid, payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, false);
    item ductdelta.change_case;
    event ductdelta.case_event;
    active_rule jsonb;
    event_data jsonb := payload;
    notice_reference text;
    agreement_reference text;
    trigger_at timestamptz;
    due_at timestamptz;
    time_zone text;
    window_size integer;
    local_cutoff timestamp;
BEGIN
    IF requested_operation IS NULL OR jsonb_typeof(payload) IS DISTINCT FROM 'object'
        OR octet_length(payload::text) > 65536 THEN
        RAISE EXCEPTION 'Invalid case action' USING ERRCODE = '22023';
    END IF;

    PERFORM FROM ductdelta.project
    WHERE (organization_id, id) = (member.organization_id, member.project_id)
    FOR SHARE;
    active_rule := ductdelta.current_notice_rule(member.organization_id, member.project_id);
    IF active_rule IS NULL THEN
        RETURN ductdelta.record_other_case_action(
            session_digest, requested_project, requested_case, requested_operation, 'notice', payload
        );
    END IF;

    member := ductdelta.case_member(session_digest, requested_project, true);
    PERFORM FROM ductdelta.project_workflow_grant
    WHERE (organization_id, project_id, actor_id, capability) =
          (member.organization_id, member.project_id, member.actor_id, 'direction')
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Case action requires a project grant' USING ERRCODE = '42501';
    END IF;

    -- Match the case recorder's write lock and check the original request before the active version.
    UPDATE ductdelta.change_case SET closeout_id = closeout_id
    WHERE (organization_id, project_id, id) = (member.organization_id, member.project_id, requested_case)
    RETURNING * INTO item;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Case unavailable' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO event FROM ductdelta.case_event
    WHERE (case_id, actor_id, operation_id) = (item.id, member.actor_id, requested_operation);
    IF FOUND THEN
        IF (event.kind, coalesce(event.notice_input, event.data)) IS DISTINCT FROM ('notice', payload) THEN
            RAISE EXCEPTION 'Operation ID already records a different action' USING ERRCODE = 'DD001';
        END IF;
        RETURN jsonb_build_object('id', event.id);
    END IF;

    IF item.closeout_id IS NOT NULL THEN
        RAISE EXCEPTION 'Case is closed' USING ERRCODE = '23514';
    END IF;
    IF member.actor_id <> (active_rule ->> 'issuer_actor_id')::uuid THEN
        RAISE EXCEPTION 'The configured issuer must record the notice' USING ERRCODE = '42501';
    END IF;
    PERFORM ductdelta.case_fields(payload, ARRAY[
        'reference', 'agreement', 'body', 'notice_rule_version', 'trigger_at', 'due_at', 'deadline_basis'
    ]);
    IF payload -> 'notice_rule_version' IS DISTINCT FROM active_rule -> 'version' THEN
        RAISE EXCEPTION 'Notice rule version changed' USING ERRCODE = 'DD005';
    END IF;
    notice_reference := ductdelta.case_text(payload, 'reference', 160);
    IF notice_reference ~ '[[:cntrl:]]' THEN
        RAISE EXCEPTION 'Use one line for the notice reference' USING ERRCODE = '22023';
    END IF;
    agreement_reference := ductdelta.case_text(payload, 'agreement', 160);
    PERFORM ductdelta.case_text(payload, 'body', 12000);
    IF agreement_reference <> active_rule ->> 'agreement'
        OR (item.agreement IS NOT NULL AND item.agreement <> agreement_reference) THEN
        RAISE EXCEPTION 'Agreement does not match the applicable rule and case' USING ERRCODE = '23514';
    END IF;
    trigger_at := ductdelta.notice_time(payload, 'trigger_at');
    time_zone := active_rule ->> 'timezone';
    window_size := (active_rule ->> 'window')::integer;
    CASE active_rule ->> 'deadline_mode'
        WHEN 'manual' THEN
            due_at := ductdelta.notice_time(payload, 'due_at');
            PERFORM ductdelta.case_text(payload, 'deadline_basis', 4000);
        WHEN 'elapsed_hours' THEN
            due_at := trigger_at + make_interval(hours => window_size);
        WHEN 'calendar_days' THEN
            local_cutoff := (trigger_at AT TIME ZONE time_zone)::date + window_size + time '23:59:59.999999';
            due_at := local_cutoff AT TIME ZONE time_zone;
            IF (due_at AT TIME ZONE time_zone) <> local_cutoff THEN
                RAISE EXCEPTION 'This calendar cutoff needs a manual deadline' USING ERRCODE = 'DD006';
            END IF;
    END CASE;
    IF active_rule ->> 'deadline_mode' <> 'manual' AND payload ?| ARRAY['due_at', 'deadline_basis'] THEN
        RAISE EXCEPTION 'Deadline is determined by the active rule' USING ERRCODE = '22023';
    END IF;
    IF due_at < trigger_at OR extract(year FROM due_at AT TIME ZONE 'UTC') NOT BETWEEN 1 AND 9999 THEN
        RAISE EXCEPTION 'Invalid deadline for this trigger' USING ERRCODE = '22023';
    END IF;

    event_data := (payload - 'notice_rule_version') || jsonb_build_object(
        'notice_rule', active_rule,
        'due_at', to_char(due_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    );
    UPDATE ductdelta.change_case SET agreement = agreement_reference WHERE id = item.id;
    INSERT INTO ductdelta.case_event (
        organization_id, project_id, case_id, actor_id, operation_id, kind, reference, data, notice_input
    ) VALUES (
        item.organization_id, item.project_id, item.id, member.actor_id, requested_operation,
        'notice', notice_reference, event_data, payload
    ) RETURNING * INTO event;
    RETURN jsonb_build_object('id', event.id);
END;
$$;

ALTER FUNCTION ductdelta.web_case_action(bytea, uuid, uuid, uuid, text, jsonb)
    RENAME TO record_other_case_action;
REVOKE EXECUTE ON FUNCTION ductdelta.record_other_case_action(bytea, uuid, uuid, uuid, text, jsonb)
    FROM ductdelta_web_runtime;

CREATE FUNCTION ductdelta.web_case_action(
    session_digest bytea, requested_project uuid, requested_case uuid, requested_operation uuid,
    action_kind text, payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF action_kind = 'notice' THEN
        RETURN ductdelta.record_project_notice(
            session_digest, requested_project, requested_case, requested_operation, payload
        );
    END IF;
    RETURN ductdelta.record_other_case_action(
        session_digest, requested_project, requested_case, requested_operation, action_kind, payload
    );
END;
$$;

REVOKE ALL ON FUNCTION ductdelta.current_notice_rule(uuid, uuid),
    ductdelta.notice_time(jsonb, text),
    ductdelta.record_project_notice(bytea, uuid, uuid, uuid, jsonb),
    ductdelta.web_project_notice_rule(bytea, uuid),
    ductdelta.web_publish_notice_rule(bytea, uuid, uuid, integer, jsonb),
    ductdelta.web_case_action(bytea, uuid, uuid, uuid, text, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION ductdelta.web_project_notice_rule(bytea, uuid),
    ductdelta.web_publish_notice_rule(bytea, uuid, uuid, integer, jsonb),
    ductdelta.web_case_action(bytea, uuid, uuid, uuid, text, jsonb) TO ductdelta_web_runtime;

COMMIT;
