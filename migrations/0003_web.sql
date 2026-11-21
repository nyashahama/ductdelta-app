BEGIN;

CREATE ROLE ductdelta_web_runtime NOLOGIN;
SET LOCAL ROLE ductdelta_owner;
GRANT USAGE ON SCHEMA ductdelta TO ductdelta_web_runtime;

CREATE TABLE ductdelta.web_access_key (
    actor_id uuid PRIMARY KEY REFERENCES ductdelta.actor,
    display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 120),
    key_digest bytea NOT NULL UNIQUE CHECK (octet_length(key_digest) = 32),
    expires_at timestamptz NOT NULL
);

CREATE TABLE ductdelta.web_session (
    digest bytea PRIMARY KEY CHECK (octet_length(digest) = 32),
    actor_id uuid NOT NULL REFERENCES ductdelta.actor,
    key_digest bytea NOT NULL,
    expires_at timestamptz NOT NULL
);

CREATE FUNCTION ductdelta.web_actor(requested_session bytea) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    authenticated_actor uuid;
BEGIN
    SELECT session.actor_id INTO authenticated_actor
    FROM ductdelta.web_session AS session
    JOIN ductdelta.web_access_key AS access_key
      ON (access_key.actor_id, access_key.key_digest) = (session.actor_id, session.key_digest)
    WHERE session.digest = requested_session AND session.expires_at > statement_timestamp()
      AND access_key.expires_at > statement_timestamp();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sign in required' USING ERRCODE = '28000';
    END IF;
    RETURN authenticated_actor;
END;
$$;

CREATE FUNCTION ductdelta.web_login(requested_key bytea, requested_session bytea) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    INSERT INTO ductdelta.web_session (digest, actor_id, key_digest, expires_at)
    SELECT requested_session, actor_id, key_digest,
           least(expires_at, statement_timestamp() + interval '12 hours')
    FROM ductdelta.web_access_key
    WHERE key_digest = requested_key AND expires_at > statement_timestamp();
    RETURN FOUND;
END;
$$;

CREATE FUNCTION ductdelta.web_logout(requested_session bytea) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    DELETE FROM ductdelta.web_session WHERE digest = requested_session;
$$;

CREATE FUNCTION ductdelta.web_self(requested_session bytea) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    authenticated_actor uuid := ductdelta.web_actor(requested_session);
BEGIN
    RETURN (SELECT jsonb_build_object('name', display_name)
            FROM ductdelta.web_access_key WHERE actor_id = authenticated_actor);
END;
$$;

CREATE FUNCTION ductdelta.web_projects(requested_session bytea) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    authenticated_actor uuid := ductdelta.web_actor(requested_session);
BEGIN
    RETURN (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id', project.id, 'name', project.name, 'permission', membership.permission
        ) ORDER BY project.name, project.id), '[]'::jsonb)
        FROM ductdelta.project_member AS membership
        JOIN ductdelta.project AS project
          ON (project.organization_id, project.id) = (membership.organization_id, membership.project_id)
        WHERE membership.actor_id = authenticated_actor
    );
END;
$$;

CREATE FUNCTION ductdelta.web_project_organization(requested_session bytea, requested_project uuid)
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    authenticated_actor uuid := ductdelta.web_actor(requested_session);
    authorized_organization uuid;
BEGIN
    SELECT organization_id INTO authorized_organization FROM ductdelta.project_member
    WHERE project_id = requested_project AND actor_id = authenticated_actor;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Project unavailable' USING ERRCODE = '42501';
    END IF;
    RETURN authorized_organization;
END;
$$;

CREATE FUNCTION ductdelta.web_observations(requested_session bytea, requested_project uuid, before_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    authorized_organization uuid := ductdelta.web_project_organization(requested_session, requested_project);
    cursor_time timestamptz;
BEGIN
    IF before_id IS NOT NULL THEN
        SELECT recorded_at INTO cursor_time FROM ductdelta.observation
        WHERE (organization_id, project_id, id) = (authorized_organization, requested_project, before_id);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Page reference unavailable' USING ERRCODE = '22023';
        END IF;
    END IF;

    RETURN (
        WITH page AS (
            SELECT id, recorded_at, location, left(btrim(regexp_replace(note, '[[:space:]]+', ' ', 'g')), 120) AS note_preview
            FROM ductdelta.observation
            WHERE (organization_id, project_id) = (authorized_organization, requested_project)
              AND (before_id IS NULL OR (recorded_at, id) < (cursor_time, before_id))
            ORDER BY recorded_at DESC, id DESC
            LIMIT 51
        ), ranked AS (
            SELECT page.*, row_number() OVER (ORDER BY recorded_at DESC, id DESC) AS position FROM page
        )
        SELECT jsonb_build_object(
            'observations', coalesce(jsonb_agg(to_jsonb(ranked) - 'position' ORDER BY position)
                FILTER (WHERE position <= 50), '[]'::jsonb),
            'next', CASE WHEN count(*) > 50 THEN max(id::text) FILTER (WHERE position = 50) END
        ) FROM ranked
    );
END;
$$;

CREATE FUNCTION ductdelta.web_observation(requested_session bytea, requested_project uuid, requested_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    authorized_organization uuid := ductdelta.web_project_organization(requested_session, requested_project);
    result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id', id, 'project_id', project_id, 'actor_id', actor_id, 'location', location,
        'observed_at', observed_at, 'recorded_at', recorded_at, 'note', note
    ) INTO result FROM ductdelta.observation
    WHERE (organization_id, project_id, id) = (authorized_organization, requested_project, requested_id);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Observation unavailable' USING ERRCODE = '42501';
    END IF;
    RETURN result;
END;
$$;

CREATE FUNCTION ductdelta.capture_for_actor(
    requested_actor uuid, requested_project uuid, requested_operation uuid,
    requested_observed_at timestamptz, requested_location text, requested_note text
) RETURNS uuid LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    allowed ductdelta.project_member%ROWTYPE;
    saved ductdelta.observation%ROWTYPE;
BEGIN
    SELECT membership.* INTO allowed FROM ductdelta.project_member AS membership
    WHERE project_id = requested_project AND actor_id = requested_actor AND permission = 'capture'
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No capture access to this project' USING ERRCODE = '42501';
    END IF;

    INSERT INTO ductdelta.observation (organization_id, project_id, actor_id, operation_id, observed_at, location, note)
    VALUES (allowed.organization_id, allowed.project_id, allowed.actor_id, requested_operation,
            requested_observed_at, requested_location, requested_note)
    ON CONFLICT (organization_id, project_id, actor_id, operation_id) DO NOTHING RETURNING * INTO saved;
    IF NOT FOUND THEN
        SELECT * INTO STRICT saved FROM ductdelta.observation
        WHERE (organization_id, project_id, actor_id, operation_id) =
              (allowed.organization_id, allowed.project_id, allowed.actor_id, requested_operation);
        IF (saved.observed_at, saved.location, saved.note)
           IS DISTINCT FROM (requested_observed_at, requested_location, requested_note) THEN
            RAISE EXCEPTION 'Operation ID already records a different observation' USING ERRCODE = 'DD001';
        END IF;
    END IF;
    RETURN saved.id;
END;
$$;

CREATE OR REPLACE FUNCTION ductdelta.capture_observation(
    requested_project uuid, requested_operation uuid, requested_observed_at timestamptz,
    requested_location text, requested_note text
) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    SELECT ductdelta.capture_for_actor(
        (SELECT id FROM ductdelta.actor WHERE database_login = SESSION_USER),
        requested_project, requested_operation, requested_observed_at, requested_location, requested_note
    );
$$;

CREATE FUNCTION ductdelta.web_capture(
    requested_session bytea, requested_project uuid, requested_operation uuid,
    requested_observed_at timestamptz, requested_location text, requested_note text
) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object('id', ductdelta.capture_for_actor(
        ductdelta.web_actor(requested_session), requested_project, requested_operation,
        requested_observed_at, requested_location, requested_note
    ));
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ductdelta FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.web_login(bytea, bytea), ductdelta.web_logout(bytea),
    ductdelta.web_self(bytea), ductdelta.web_projects(bytea),
    ductdelta.web_observations(bytea, uuid, uuid), ductdelta.web_observation(bytea, uuid, uuid),
    ductdelta.web_capture(bytea, uuid, uuid, timestamptz, text, text)
TO ductdelta_web_runtime;

COMMIT;
