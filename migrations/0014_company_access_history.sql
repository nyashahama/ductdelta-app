BEGIN;

SET LOCAL ROLE ductdelta_owner;

ALTER TABLE ductdelta.organization
    ADD COLUMN invitation_lifetime_days integer NOT NULL DEFAULT 7
    CHECK (invitation_lifetime_days BETWEEN 1 AND 14);

CREATE TABLE ductdelta.company_access_event (
    sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES ductdelta.organization,
    actor_id uuid NOT NULL REFERENCES ductdelta.actor,
    kind text NOT NULL CHECK (kind IN (
        'invitation_created', 'invitation_revoked', 'invitation_accepted',
        'invitation_lifetime_changed', 'company_role_changed', 'company_member_removed',
        'project_access_changed'
    )),
    target_id uuid,
    project_id uuid,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    previous_value jsonb,
    new_value jsonb,
    CHECK (previous_value IS DISTINCT FROM new_value)
);

CREATE INDEX company_access_event_page ON ductdelta.company_access_event (organization_id, sequence DESC);

CREATE FUNCTION ductdelta.invitation_set_expiry() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    SELECT clock_timestamp() + interval '24 hours' * invitation_lifetime_days INTO NEW.expires_at
    FROM ductdelta.organization WHERE id = NEW.organization_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER invitation_set_expiry
BEFORE INSERT ON ductdelta.company_invitation
FOR EACH ROW EXECUTE FUNCTION ductdelta.invitation_set_expiry();

CREATE FUNCTION ductdelta.record_invitation_access() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO ductdelta.company_access_event (organization_id, actor_id, kind, target_id, new_value)
        VALUES (NEW.organization_id, NEW.inviter_id, 'invitation_created', NEW.id,
                jsonb_build_object('role', NEW.role, 'expires_at', NEW.expires_at));
    ELSIF OLD.accepted_by IS NULL AND NEW.accepted_by IS NOT NULL THEN
        INSERT INTO ductdelta.company_access_event
            (organization_id, actor_id, kind, target_id, previous_value, new_value)
        VALUES (NEW.organization_id, NEW.accepted_by, 'invitation_accepted', NEW.id,
                jsonb_build_object('status', 'pending'),
                jsonb_build_object('status', 'accepted', 'role', NEW.role));
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER record_invitation_access
AFTER INSERT OR UPDATE OF accepted_by ON ductdelta.company_invitation
FOR EACH ROW EXECUTE FUNCTION ductdelta.record_invitation_access();

CREATE FUNCTION ductdelta.web_invitation_lifetime(requested_session bytea, company_id uuid) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM ductdelta.company_admin(requested_session, company_id);
    RETURN (SELECT invitation_lifetime_days FROM ductdelta.organization WHERE id = company_id);
END;
$$;

CREATE FUNCTION ductdelta.web_set_invitation_lifetime(requested_session bytea, company_id uuid, days integer)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    administrator uuid := ductdelta.lock_company_admin(requested_session, company_id);
    previous_days integer;
BEGIN
    IF days IS NULL OR days NOT BETWEEN 1 AND 14 THEN
        RAISE EXCEPTION 'Choose an invitation lifetime between 1 and 14 days' USING ERRCODE = '22023';
    END IF;
    SELECT invitation_lifetime_days INTO previous_days FROM ductdelta.organization WHERE id = company_id;
    IF previous_days <> days THEN
        UPDATE ductdelta.organization SET invitation_lifetime_days = days WHERE id = company_id;
        INSERT INTO ductdelta.company_access_event
            (organization_id, actor_id, kind, previous_value, new_value)
        VALUES (company_id, administrator, 'invitation_lifetime_changed',
                jsonb_build_object('days', previous_days), jsonb_build_object('days', days));
    END IF;
    RETURN days;
END;
$$;

CREATE FUNCTION ductdelta.access_history_name(label text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp
RETURN CASE WHEN strpos(label, '@') = 0 THEN label END;

CREATE FUNCTION ductdelta.web_company_access_history(requested_session bytea, company_id uuid, before_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    before_sequence bigint;
BEGIN
    PERFORM ductdelta.company_admin(requested_session, company_id);
    IF before_id IS NOT NULL THEN
        SELECT sequence INTO before_sequence FROM ductdelta.company_access_event
        WHERE organization_id = company_id AND id = before_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Access history page unavailable' USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN (
        WITH page AS MATERIALIZED (
            SELECT * FROM ductdelta.company_access_event
            WHERE organization_id = company_id AND sequence < coalesce(before_sequence, 9223372036854775807)
            ORDER BY sequence DESC LIMIT 51
        ), visible AS (
            SELECT page.sequence, page.id, jsonb_build_object(
                'id', page.id, 'kind', page.kind, 'actor_id', page.actor_id,
                'actor_name', ductdelta.access_history_name(actor.display_name),
                'target_id', page.target_id,
                'target_name', ductdelta.access_history_name(coalesce(invitation.name, target.display_name)),
                'project_id', page.project_id, 'project_name', ductdelta.access_history_name(project.name),
                'recorded_at', page.recorded_at, 'before', page.previous_value, 'after', page.new_value
            ) AS event
            FROM page
            LEFT JOIN ductdelta.web_access_key AS actor ON actor.actor_id = page.actor_id
            LEFT JOIN ductdelta.company_invitation AS invitation
              ON (invitation.organization_id, invitation.id) = (page.organization_id, page.target_id)
              AND page.kind IN ('invitation_created', 'invitation_accepted', 'invitation_revoked')
            LEFT JOIN ductdelta.web_access_key AS target ON target.actor_id = page.target_id
              AND page.kind IN ('project_access_changed', 'company_role_changed', 'company_member_removed')
            LEFT JOIN ductdelta.project AS project
              ON (project.organization_id, project.id) = (page.organization_id, page.project_id)
            ORDER BY page.sequence DESC LIMIT 50
        )
        SELECT jsonb_build_object(
            'events', coalesce(jsonb_agg(event ORDER BY visible.sequence DESC), '[]'::jsonb),
            'next_before', CASE WHEN (SELECT count(*) FROM page) > 50 THEN (
                SELECT id FROM visible ORDER BY sequence LIMIT 1
            ) END
        ) FROM visible
    );
END;
$$;

CREATE OR REPLACE FUNCTION ductdelta.web_revoke_invite(
    requested_session bytea, company_id uuid, invite_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    administrator uuid := ductdelta.lock_company_admin(requested_session, company_id);
BEGIN
    UPDATE ductdelta.company_invitation SET revoked_at = clock_timestamp()
    WHERE organization_id = company_id AND id = invite_id AND accepted_by IS NULL AND revoked_at IS NULL;
    IF FOUND THEN
        INSERT INTO ductdelta.company_access_event
            (organization_id, actor_id, kind, target_id, previous_value, new_value)
        VALUES (company_id, administrator, 'invitation_revoked', invite_id,
                jsonb_build_object('status', 'pending'), jsonb_build_object('status', 'revoked'));
    ELSE
        PERFORM FROM ductdelta.company_invitation
        WHERE organization_id = company_id AND id = invite_id AND accepted_by IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Invitation unavailable' USING ERRCODE = '42501';
        END IF;
    END IF;
END;
$$;

CREATE FUNCTION ductdelta.company_project_access_state(company_id uuid, scoped_project uuid, member_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp
RETURN (
    SELECT jsonb_build_object('permission', membership.permission, 'capabilities', ARRAY(
        SELECT grant_row.capability FROM ductdelta.project_workflow_grant AS grant_row
        WHERE (grant_row.organization_id, grant_row.project_id, grant_row.actor_id) =
              (company_id, scoped_project, member_id)
        ORDER BY grant_row.capability
    ))
    FROM ductdelta.project_member AS membership
    WHERE (membership.organization_id, membership.project_id, membership.actor_id) =
          (company_id, scoped_project, member_id)
);

CREATE OR REPLACE FUNCTION ductdelta.web_create_project(
    requested_session bytea, company_id uuid, requested_operation uuid, project_name text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    creator uuid := ductdelta.lock_company_admin(requested_session, company_id);
    cleaned_name text := ductdelta.setup_name(project_name);
    saved_id uuid;
    saved_name text;
BEGIN
    SELECT project.id, project.name INTO saved_id, saved_name
    FROM ductdelta.project_creation AS creation
    JOIN ductdelta.project AS project ON project.id = creation.project_id
    WHERE (creation.organization_id, creation.actor_id, creation.operation_id) =
          (company_id, creator, requested_operation);
    IF FOUND THEN
        IF saved_name IS DISTINCT FROM cleaned_name THEN
            RAISE EXCEPTION 'Operation conflicts with an existing project' USING ERRCODE = 'DD001';
        END IF;
    ELSE
        saved_id := gen_random_uuid();
        INSERT INTO ductdelta.project (id, organization_id, name) VALUES (saved_id, company_id, cleaned_name);
        INSERT INTO ductdelta.project_creation (organization_id, actor_id, operation_id, project_id)
        VALUES (company_id, creator, requested_operation, saved_id);
        INSERT INTO ductdelta.project_member (organization_id, project_id, actor_id, permission)
        VALUES (company_id, saved_id, creator, 'capture');
        INSERT INTO ductdelta.project_workflow_grant (organization_id, project_id, actor_id, capability)
        SELECT company_id, saved_id, creator, capability
        FROM unnest(ARRAY['direction', 'commercial', 'finance']) AS capability;
        INSERT INTO ductdelta.company_access_event
            (organization_id, actor_id, kind, target_id, project_id, new_value)
        VALUES (company_id, creator, 'project_access_changed', creator, saved_id,
                ductdelta.company_project_access_state(company_id, saved_id, creator));
    END IF;
    RETURN jsonb_build_object('id', saved_id, 'name', cleaned_name);
END;
$$;

CREATE OR REPLACE FUNCTION ductdelta.web_change_company_member(
    requested_session bytea, company_id uuid, member_id uuid, new_role text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    administrator uuid := ductdelta.lock_company_admin(requested_session, company_id);
    previous_role text;
BEGIN
    SELECT role INTO previous_role FROM ductdelta.organization_member
    WHERE organization_id = company_id AND actor_id = member_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Company member unavailable' USING ERRCODE = '42501';
    END IF;

    IF previous_role = new_role THEN
        RETURN;
    END IF;
    IF previous_role = 'admin' THEN
        PERFORM FROM ductdelta.organization_member
        WHERE organization_id = company_id AND actor_id <> member_id AND role = 'admin';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'The company needs at least one administrator' USING ERRCODE = 'DD002';
        END IF;
        WITH revoked AS (
            UPDATE ductdelta.company_invitation SET revoked_at = clock_timestamp()
            WHERE organization_id = company_id AND inviter_id = member_id
              AND accepted_by IS NULL AND revoked_at IS NULL
            RETURNING id
        )
        INSERT INTO ductdelta.company_access_event
            (organization_id, actor_id, kind, target_id, previous_value, new_value)
        SELECT company_id, administrator, 'invitation_revoked', id,
               jsonb_build_object('status', 'pending'),
               jsonb_build_object('status', 'revoked', 'reason', 'inviter_lost_admin')
        FROM revoked ORDER BY id;
    END IF;

    IF new_role IS NULL THEN
        INSERT INTO ductdelta.company_access_event
            (organization_id, actor_id, kind, target_id, project_id, previous_value)
        SELECT company_id, administrator, 'project_access_changed', member_id, project_id,
               ductdelta.company_project_access_state(company_id, project_id, member_id)
        FROM ductdelta.project_member
        WHERE organization_id = company_id AND actor_id = member_id ORDER BY project_id;

        DELETE FROM ductdelta.project_member WHERE organization_id = company_id AND actor_id = member_id;
        DELETE FROM ductdelta.organization_member WHERE organization_id = company_id AND actor_id = member_id;
        INSERT INTO ductdelta.company_access_event
            (organization_id, actor_id, kind, target_id, previous_value)
        VALUES (company_id, administrator, 'company_member_removed', member_id,
                jsonb_build_object('role', previous_role));
    ELSE
        UPDATE ductdelta.organization_member SET role = new_role
        WHERE organization_id = company_id AND actor_id = member_id;
        INSERT INTO ductdelta.company_access_event
            (organization_id, actor_id, kind, target_id, previous_value, new_value)
        VALUES (company_id, administrator, 'company_role_changed', member_id,
                jsonb_build_object('role', previous_role), jsonb_build_object('role', new_role));
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION ductdelta.web_change_project_access(
    requested_session bytea, company_id uuid, requested_project uuid, member_id uuid,
    new_permission text, new_capabilities text[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    administrator uuid := ductdelta.lock_company_admin(requested_session, company_id);
    previous_access jsonb;
    updated_access jsonb;
BEGIN
    PERFORM FROM ductdelta.project WHERE organization_id = company_id AND id = requested_project;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Project unavailable' USING ERRCODE = '42501';
    END IF;
    PERFORM FROM ductdelta.organization_member WHERE organization_id = company_id AND actor_id = member_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Company member unavailable' USING ERRCODE = '42501';
    END IF;
    IF new_capabilities IS NULL OR (new_permission IS NULL AND cardinality(new_capabilities) > 0)
        OR EXISTS (SELECT FROM unnest(new_capabilities) AS capability
                   WHERE capability IS NULL OR capability NOT IN ('direction', 'commercial', 'finance')) THEN
        RAISE EXCEPTION 'Choose valid project capabilities' USING ERRCODE = '22023';
    END IF;
    previous_access := ductdelta.company_project_access_state(company_id, requested_project, member_id);
    IF new_permission IS NULL THEN
        DELETE FROM ductdelta.project_member
        WHERE (organization_id, project_id, actor_id) = (company_id, requested_project, member_id);
    ELSE
        INSERT INTO ductdelta.project_member (organization_id, project_id, actor_id, permission)
        VALUES (company_id, requested_project, member_id, new_permission)
        ON CONFLICT (organization_id, project_id, actor_id) DO UPDATE SET permission = excluded.permission;
        DELETE FROM ductdelta.project_workflow_grant
        WHERE (organization_id, project_id, actor_id) = (company_id, requested_project, member_id)
          AND capability <> ALL (new_capabilities);
        INSERT INTO ductdelta.project_workflow_grant (organization_id, project_id, actor_id, capability)
        SELECT company_id, requested_project, member_id, capability
        FROM unnest(new_capabilities) AS capability ON CONFLICT DO NOTHING;
        updated_access := ductdelta.company_project_access_state(company_id, requested_project, member_id);
    END IF;
    IF previous_access IS DISTINCT FROM updated_access THEN
        INSERT INTO ductdelta.company_access_event
            (organization_id, actor_id, kind, target_id, project_id, previous_value, new_value)
        VALUES (company_id, administrator, 'project_access_changed', member_id, requested_project,
                previous_access, updated_access);
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION ductdelta.invitation_set_expiry(), ductdelta.record_invitation_access(),
    ductdelta.web_invitation_lifetime(bytea, uuid), ductdelta.web_set_invitation_lifetime(bytea, uuid, integer),
    ductdelta.access_history_name(text), ductdelta.web_company_access_history(bytea, uuid, uuid),
    ductdelta.company_project_access_state(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.web_invitation_lifetime(bytea, uuid),
    ductdelta.web_set_invitation_lifetime(bytea, uuid, integer),
    ductdelta.web_company_access_history(bytea, uuid, uuid) TO ductdelta_web_runtime;

COMMIT;
