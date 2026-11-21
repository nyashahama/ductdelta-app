BEGIN;

CREATE ROLE ductdelta_owner NOLOGIN;
CREATE ROLE ductdelta_runtime NOLOGIN;
CREATE SCHEMA ductdelta AUTHORIZATION ductdelta_owner;
SET LOCAL ROLE ductdelta_owner;

REVOKE ALL ON SCHEMA ductdelta FROM PUBLIC;
GRANT USAGE ON SCHEMA ductdelta TO ductdelta_runtime;

CREATE TABLE ductdelta.organization (
    id uuid PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE ductdelta.project (
    id uuid PRIMARY KEY,
    organization_id uuid NOT NULL REFERENCES ductdelta.organization,
    name text NOT NULL,
    UNIQUE (organization_id, id)
);

CREATE TABLE ductdelta.actor (
    id uuid PRIMARY KEY,
    database_login name NOT NULL UNIQUE
);

CREATE TABLE ductdelta.project_member (
    organization_id uuid NOT NULL,
    project_id uuid NOT NULL,
    actor_id uuid NOT NULL REFERENCES ductdelta.actor,
    permission text NOT NULL CHECK (permission IN ('capture', 'read')),
    PRIMARY KEY (organization_id, project_id, actor_id),
    FOREIGN KEY (organization_id, project_id) REFERENCES ductdelta.project (organization_id, id)
);

CREATE TABLE ductdelta.observation (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    project_id uuid NOT NULL,
    actor_id uuid NOT NULL REFERENCES ductdelta.actor,
    operation_id uuid NOT NULL,
    observed_at timestamptz CHECK (
        observed_at >= timestamptz '0001-01-01 00:00:00+00'
        AND observed_at < timestamptz '10000-01-01 00:00:00+00'
    ),
    recorded_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    location text CHECK (char_length(location) <= 120 AND location ~ '[^[:space:]]'),
    note text NOT NULL CHECK (char_length(note) <= 4000 AND note ~ '[^[:space:]]'),
    FOREIGN KEY (organization_id, project_id) REFERENCES ductdelta.project (organization_id, id),
    UNIQUE (organization_id, project_id, actor_id, operation_id)
);

CREATE FUNCTION ductdelta.capture_observation(
    requested_project uuid,
    requested_operation uuid,
    requested_observed_at timestamptz,
    requested_location text,
    requested_note text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    access_record ductdelta.project_member%ROWTYPE;
    saved_observation ductdelta.observation%ROWTYPE;
BEGIN
    -- The login remains the actor even if the session switches to its group role.
    SELECT member.* INTO access_record
    FROM ductdelta.actor AS account
    JOIN ductdelta.project_member AS member ON member.actor_id = account.id
    WHERE account.database_login = SESSION_USER
      AND member.project_id = requested_project
      AND member.permission = 'capture'
    FOR SHARE OF account, member;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No capture access to this project' USING ERRCODE = '42501';
    END IF;

    INSERT INTO ductdelta.observation (
        organization_id, project_id, actor_id, operation_id, observed_at, location, note
    ) VALUES (
        access_record.organization_id, access_record.project_id, access_record.actor_id,
        requested_operation, requested_observed_at, requested_location, requested_note
    )
    ON CONFLICT (organization_id, project_id, actor_id, operation_id) DO NOTHING
    RETURNING * INTO saved_observation;

    IF NOT FOUND THEN
        -- A competing insert may have committed while the unique check was waiting.
        SELECT * INTO STRICT saved_observation
        FROM ductdelta.observation
        WHERE organization_id = access_record.organization_id
          AND project_id = access_record.project_id
          AND actor_id = access_record.actor_id
          AND operation_id = requested_operation;

        IF (saved_observation.observed_at, saved_observation.location, saved_observation.note)
           IS DISTINCT FROM (requested_observed_at, requested_location, requested_note) THEN
            RAISE EXCEPTION 'Operation ID already records a different observation'
                USING ERRCODE = 'DD001';
        END IF;
    END IF;

    RETURN saved_observation.id;
END;
$$;

CREATE FUNCTION ductdelta.read_observation(requested_project uuid, requested_observation uuid)
RETURNS TABLE (
    id uuid, project_id uuid, actor_id uuid, observed_at timestamptz,
    recorded_at timestamptz, location text, note text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT observation.id, observation.project_id, observation.actor_id, observation.observed_at,
           observation.recorded_at, observation.location, observation.note
    FROM ductdelta.observation AS observation
    JOIN ductdelta.project_member AS member
        ON (member.organization_id, member.project_id) =
           (observation.organization_id, observation.project_id)
    JOIN ductdelta.actor AS account ON account.id = member.actor_id
    WHERE observation.project_id = requested_project
      AND observation.id = requested_observation
      AND account.database_login = SESSION_USER;
$$;

REVOKE ALL ON FUNCTION ductdelta.capture_observation(uuid, uuid, timestamptz, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ductdelta.read_observation(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.capture_observation(uuid, uuid, timestamptz, text, text)
    TO ductdelta_runtime;
GRANT EXECUTE ON FUNCTION ductdelta.read_observation(uuid, uuid) TO ductdelta_runtime;

COMMIT;
