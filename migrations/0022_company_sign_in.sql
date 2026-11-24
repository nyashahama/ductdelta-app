BEGIN;

SET LOCAL ROLE ductdelta_owner;

CREATE TABLE ductdelta.company_entra (
    company_id uuid PRIMARY KEY REFERENCES ductdelta.organization,
    tenant_id uuid NOT NULL,
    mfa_context text CHECK (mfa_context ~ '^c([1-9]|[1-9][0-9])$')
);

CREATE TABLE ductdelta.company_entra_member (
    company_id uuid REFERENCES ductdelta.company_entra ON DELETE CASCADE,
    actor_id uuid,
    object_id uuid NOT NULL,
    PRIMARY KEY (company_id, actor_id),
    UNIQUE (company_id, object_id),
    FOREIGN KEY (company_id, actor_id) REFERENCES ductdelta.organization_member (organization_id, actor_id)
        ON DELETE CASCADE
);

ALTER TABLE ductdelta.web_session
    ADD COLUMN entra_company uuid REFERENCES ductdelta.organization,
    ADD COLUMN entra_tenant uuid,
    ADD COLUMN entra_object uuid,
    ADD COLUMN entra_context text;

CREATE TABLE ductdelta.entra_attempt (
    state_digest bytea PRIMARY KEY CHECK (octet_length(state_digest) = 32),
    browser_digest bytea NOT NULL CHECK (octet_length(browser_digest) = 32),
    company_id uuid NOT NULL REFERENCES ductdelta.organization,
    tenant_id uuid NOT NULL,
    mfa_context text,
    nonce text NOT NULL,
    verifier text NOT NULL,
    expires_at timestamptz NOT NULL DEFAULT clock_timestamp() + interval '10 minutes'
);
CREATE INDEX entra_attempt_expiry ON ductdelta.entra_attempt (expires_at);

CREATE FUNCTION ductdelta.configure_company_entra(company uuid, tenant uuid, context text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM FROM ductdelta.organization WHERE id = company FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Company unavailable' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT FROM ductdelta.company_entra WHERE company_id = company AND tenant_id <> tenant)
       AND EXISTS (SELECT FROM ductdelta.company_entra_member WHERE company_id = company) THEN
        RAISE EXCEPTION 'Unlink work accounts before changing the tenant' USING ERRCODE = 'DD001';
    END IF;
    IF context IS NOT NULL AND EXISTS (
        SELECT FROM ductdelta.organization_member AS member
        WHERE member.organization_id = company AND (
            member.role = 'admin' OR EXISTS (
                SELECT FROM ductdelta.project_workflow_grant AS grant_row
                WHERE grant_row.organization_id = company AND grant_row.actor_id = member.actor_id
                  AND grant_row.capability = 'finance'
            )
        ) AND NOT EXISTS (
            SELECT FROM ductdelta.company_entra_member AS link
            WHERE link.company_id = company AND link.actor_id = member.actor_id
        )
    ) THEN
        RAISE EXCEPTION 'Link current administrators and finance members before requiring MFA' USING ERRCODE = 'DD001';
    END IF;
    INSERT INTO ductdelta.company_entra VALUES (company, tenant, context)
    ON CONFLICT (company_id) DO UPDATE SET tenant_id = excluded.tenant_id, mfa_context = excluded.mfa_context;
END;
$$;

CREATE FUNCTION ductdelta.link_company_entra(company uuid, account uuid, object_key uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM FROM ductdelta.organization WHERE id = company FOR UPDATE;
    PERFORM FROM ductdelta.web_access_key WHERE actor_id = account AND email IS NOT NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Enroll the workspace account with email before linking Entra' USING ERRCODE = '42501';
    END IF;
    INSERT INTO ductdelta.company_entra_member VALUES (company, account, object_key)
    ON CONFLICT (company_id, actor_id) DO NOTHING;
    IF NOT EXISTS (SELECT FROM ductdelta.company_entra_member
                   WHERE company_id = company AND actor_id = account AND object_id = object_key) THEN
        RAISE EXCEPTION 'Unlink the existing work account before changing it' USING ERRCODE = 'DD001';
    END IF;
END;
$$;

CREATE FUNCTION ductdelta.unlink_company_entra(company uuid, account uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM FROM ductdelta.organization WHERE id = company FOR UPDATE;
    DELETE FROM ductdelta.company_entra_member WHERE company_id = company AND actor_id = account;
    DELETE FROM ductdelta.web_session WHERE entra_company = company AND actor_id = account;
END;
$$;

CREATE FUNCTION ductdelta.web_entra_companies(session_digest bytea) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', company.id, 'name', company.name)
                             ORDER BY company.name, company.id), '[]'::jsonb)
    FROM ductdelta.organization_member AS member
    JOIN ductdelta.company_entra AS entra ON entra.company_id = member.organization_id
    JOIN ductdelta.organization AS company ON company.id = entra.company_id
    WHERE member.actor_id = ductdelta.web_actor(session_digest)
$$;

CREATE FUNCTION ductdelta.web_entra_configured() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (SELECT FROM ductdelta.company_entra)
$$;

CREATE FUNCTION ductdelta.web_start_entra(
    company uuid, requested_state bytea, browser bytea, requested_nonce text, requested_verifier text
) RETURNS TABLE (tenant_id uuid, mfa_context text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    -- Limit active starts across all processes. Expired attempts are discarded.
    PERFORM pg_advisory_xact_lock(746231, 2);
    DELETE FROM ductdelta.entra_attempt WHERE expires_at <= clock_timestamp();
    IF EXISTS (SELECT FROM ductdelta.entra_attempt WHERE company_id = company OFFSET 199)
       OR EXISTS (SELECT FROM ductdelta.entra_attempt OFFSET 1999) THEN
        RETURN;
    END IF;
    RETURN QUERY
    INSERT INTO ductdelta.entra_attempt (
        state_digest, browser_digest, company_id, tenant_id, mfa_context, nonce, verifier
    )
    SELECT requested_state, browser, entra.company_id, entra.tenant_id, entra.mfa_context, requested_nonce, requested_verifier
    FROM ductdelta.company_entra AS entra WHERE entra.company_id = company
    RETURNING entra_attempt.tenant_id, entra_attempt.mfa_context;
END;
$$;

CREATE FUNCTION ductdelta.web_take_entra(requested_state bytea, browser bytea)
RETURNS TABLE (company_id uuid, tenant_id uuid, mfa_context text, nonce text, verifier text)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    DELETE FROM ductdelta.entra_attempt AS attempt
    WHERE attempt.state_digest = requested_state AND attempt.browser_digest = browser
      AND attempt.expires_at > clock_timestamp()
    RETURNING attempt.company_id, attempt.tenant_id, attempt.mfa_context, attempt.nonce, attempt.verifier
$$;

CREATE FUNCTION ductdelta.web_entra_login(
    company uuid, tenant uuid, object_key uuid, verified_context text, session_digest bytea, lifetime integer
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM FROM ductdelta.organization WHERE id = company FOR UPDATE;
    INSERT INTO ductdelta.web_session (
        digest, actor_id, key_digest, expires_at, entra_company, entra_tenant, entra_object, entra_context
    )
    SELECT session_digest, access.actor_id, access.key_digest,
           clock_timestamp() + make_interval(secs => lifetime),
           company, tenant, object_key, verified_context
    FROM ductdelta.company_entra AS entra
    JOIN ductdelta.company_entra_member AS link ON link.company_id = entra.company_id
    JOIN ductdelta.web_access_key AS access ON access.actor_id = link.actor_id
    WHERE entra.company_id = company AND entra.tenant_id = tenant AND link.object_id = object_key
      AND access.email IS NOT NULL AND access.expires_at > clock_timestamp() AND lifetime BETWEEN 1 AND 3600
      AND (entra.mfa_context IS NULL OR entra.mfa_context = verified_context);
    RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION ductdelta.web_actor(requested_session bytea) RETURNS uuid
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
      AND access_key.expires_at > statement_timestamp()
      AND (session.entra_company IS NULL OR EXISTS (
          SELECT FROM ductdelta.company_entra AS entra
          JOIN ductdelta.company_entra_member AS link ON link.company_id = entra.company_id
          WHERE entra.company_id = session.entra_company AND entra.tenant_id = session.entra_tenant
            AND link.actor_id = session.actor_id AND link.object_id = session.entra_object
      ));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sign in required' USING ERRCODE = '28000';
    END IF;
    RETURN authenticated_actor;
END;
$$;

CREATE FUNCTION ductdelta.require_company_mfa(requested_session bytea, company uuid) RETURNS void
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (SELECT FROM ductdelta.company_entra WHERE company_id = company AND mfa_context IS NOT NULL)
       AND NOT EXISTS (
           SELECT FROM ductdelta.web_session AS session
           JOIN ductdelta.company_entra AS entra ON entra.company_id = session.entra_company
           WHERE session.digest = requested_session AND entra.company_id = company
             AND session.entra_tenant = entra.tenant_id AND session.entra_context = entra.mfa_context
             AND session.expires_at > statement_timestamp()
       ) THEN
        RAISE EXCEPTION 'Company work-account authentication required' USING ERRCODE = 'DD007';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION ductdelta.company_admin(requested_session bytea, company_id uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    authenticated_actor uuid := ductdelta.web_actor(requested_session);
BEGIN
    PERFORM FROM ductdelta.organization_member
    WHERE organization_id = company_id AND actor_id = authenticated_actor AND role = 'admin';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Company unavailable' USING ERRCODE = '42501';
    END IF;
    PERFORM ductdelta.require_company_mfa(requested_session, company_id);
    RETURN authenticated_actor;
END;
$$;

CREATE OR REPLACE FUNCTION ductdelta.case_member(session_digest bytea, requested_project uuid, write_access boolean)
RETURNS ductdelta.project_member
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member;
    actor uuid := ductdelta.web_actor(session_digest);
BEGIN
    IF write_access THEN
        SELECT * INTO member FROM ductdelta.project_member AS candidate
        WHERE candidate.project_id = requested_project AND candidate.actor_id = actor FOR SHARE;
    ELSE
        SELECT * INTO member FROM ductdelta.project_member AS candidate
        WHERE candidate.project_id = requested_project AND candidate.actor_id = actor;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Project unavailable' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (
        SELECT FROM ductdelta.project_workflow_grant AS grant_row
        WHERE grant_row.organization_id = member.organization_id AND grant_row.project_id = member.project_id
          AND grant_row.actor_id = actor AND grant_row.capability = 'finance'
    ) THEN
        PERFORM ductdelta.require_company_mfa(session_digest, member.organization_id);
    END IF;
    RETURN member;
END;
$$;

REVOKE ALL ON FUNCTION ductdelta.configure_company_entra(uuid,uuid,text), ductdelta.link_company_entra(uuid,uuid,uuid),
    ductdelta.unlink_company_entra(uuid,uuid), ductdelta.require_company_mfa(bytea,uuid),
    ductdelta.web_entra_companies(bytea), ductdelta.web_entra_configured(),
    ductdelta.web_start_entra(uuid,bytea,bytea,text,text),
    ductdelta.web_take_entra(bytea,bytea), ductdelta.web_entra_login(uuid,uuid,uuid,text,bytea,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.configure_company_entra(uuid,uuid,text), ductdelta.link_company_entra(uuid,uuid,uuid),
    ductdelta.unlink_company_entra(uuid,uuid) TO ductdelta_company_bootstrap;
GRANT EXECUTE ON FUNCTION ductdelta.web_entra_companies(bytea), ductdelta.web_entra_configured(),
    ductdelta.web_start_entra(uuid,bytea,bytea,text,text),
    ductdelta.web_take_entra(bytea,bytea), ductdelta.web_entra_login(uuid,uuid,uuid,text,bytea,integer) TO ductdelta_web_runtime;

COMMIT;
