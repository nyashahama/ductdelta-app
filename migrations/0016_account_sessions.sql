BEGIN;

SET LOCAL ROLE ductdelta_owner;

ALTER TABLE ductdelta.web_session
    ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    ADD COLUMN created_at timestamptz;
-- Sessions created before this migration have no recorded start time.
ALTER TABLE ductdelta.web_session ALTER COLUMN created_at SET DEFAULT statement_timestamp();
CREATE INDEX web_session_actor ON ductdelta.web_session (actor_id);

CREATE FUNCTION ductdelta.web_account_sessions(requested_session bytea) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    authenticated_actor uuid := ductdelta.web_actor(requested_session);
BEGIN
    RETURN (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id', session.id, 'created_at', session.created_at, 'expires_at', session.expires_at,
            'current', session.digest = requested_session
        ) ORDER BY (session.digest = requested_session) DESC, session.created_at DESC NULLS LAST, session.id), '[]'::jsonb)
        FROM ductdelta.web_session AS session
        JOIN ductdelta.web_access_key AS access_key
          ON (access_key.actor_id, access_key.key_digest) = (session.actor_id, session.key_digest)
        WHERE session.actor_id = authenticated_actor AND session.expires_at > statement_timestamp()
          AND access_key.expires_at > statement_timestamp()
    );
END;
$$;

CREATE FUNCTION ductdelta.web_revoke_account_sessions(requested_session bytea, requested_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    authenticated_actor uuid := ductdelta.web_actor(requested_session);
BEGIN
    -- Two sessions can request revocation at the same time. Check the caller again after taking the account lock.
    PERFORM id FROM ductdelta.actor WHERE id = authenticated_actor FOR NO KEY UPDATE;
    PERFORM ductdelta.web_actor(requested_session);

    DELETE FROM ductdelta.web_session AS session
    USING ductdelta.web_access_key AS access_key
    WHERE session.actor_id = authenticated_actor AND session.digest <> requested_session
      AND (access_key.actor_id, access_key.key_digest) = (session.actor_id, session.key_digest)
      AND session.expires_at > statement_timestamp() AND access_key.expires_at > statement_timestamp()
      AND (requested_id IS NULL OR session.id = requested_id);
    IF requested_id IS NOT NULL AND NOT FOUND THEN
        RAISE EXCEPTION 'Session unavailable' USING ERRCODE = '42501';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION ductdelta.web_account_sessions(bytea),
    ductdelta.web_revoke_account_sessions(bytea, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.web_account_sessions(bytea),
    ductdelta.web_revoke_account_sessions(bytea, uuid) TO ductdelta_web_runtime;

COMMIT;
