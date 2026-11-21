BEGIN;

SET LOCAL ROLE ductdelta_owner;

CREATE INDEX observation_project_recorded_idx
    ON ductdelta.observation (organization_id, project_id, recorded_at DESC, id DESC);

CREATE FUNCTION ductdelta.list_observations(requested_project uuid, requested_before uuid)
RETURNS TABLE (id uuid, recorded_at timestamptz, location text, note_preview text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    authorized_organization uuid;
    cursor_time timestamptz;
BEGIN
    SELECT member.organization_id INTO authorized_organization
    FROM ductdelta.project_member AS member
    JOIN ductdelta.actor AS account ON account.id = member.actor_id
    WHERE member.project_id = requested_project
      AND account.database_login = SESSION_USER;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Project unavailable' USING ERRCODE = '42501';
    END IF;

    IF requested_before IS NOT NULL THEN
        SELECT observation.recorded_at INTO cursor_time
        FROM ductdelta.observation AS observation
        WHERE observation.organization_id = authorized_organization
          AND observation.project_id = requested_project
          AND observation.id = requested_before;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Page reference unavailable' USING ERRCODE = '22023';
        END IF;
    END IF;

    -- The extra row tells the caller whether another page exists.
    RETURN QUERY
    SELECT observation.id, observation.recorded_at, observation.location,
           left(btrim(regexp_replace(observation.note, '[[:space:]]+', ' ', 'g')), 121)
    FROM ductdelta.observation AS observation
    WHERE observation.organization_id = authorized_organization
      AND observation.project_id = requested_project
      AND (requested_before IS NULL
           OR (observation.recorded_at, observation.id) < (cursor_time, requested_before))
    ORDER BY observation.recorded_at DESC, observation.id DESC
    LIMIT 51;
END;
$$;

REVOKE ALL ON FUNCTION ductdelta.list_observations(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.list_observations(uuid, uuid) TO ductdelta_runtime;

COMMIT;
