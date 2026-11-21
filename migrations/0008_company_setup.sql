BEGIN;

SET LOCAL ROLE ductdelta_owner;

ALTER TABLE ductdelta.actor ALTER COLUMN database_login DROP NOT NULL;

CREATE TABLE ductdelta.organization_member (
    organization_id uuid NOT NULL REFERENCES ductdelta.organization,
    actor_id uuid NOT NULL REFERENCES ductdelta.actor,
    role text NOT NULL CHECK (role IN ('admin', 'member')),
    PRIMARY KEY (organization_id, actor_id)
);

INSERT INTO ductdelta.organization_member (organization_id, actor_id, role)
SELECT DISTINCT organization_id, actor_id, 'member' FROM ductdelta.project_member;

CREATE TABLE ductdelta.web_recovery_key (
    actor_id uuid PRIMARY KEY REFERENCES ductdelta.actor,
    key_digest bytea NOT NULL UNIQUE CHECK (octet_length(key_digest) = 32)
);

CREATE FUNCTION ductdelta.setup_name(input text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF input IS NULL OR input !~ '[^[:space:]]' OR char_length(input) > 120 THEN
        RAISE EXCEPTION 'Enter a name of up to 120 characters' USING ERRCODE = '22023';
    END IF;
    RETURN btrim(input);
END;
$$;

CREATE FUNCTION ductdelta.setup_account(
    display_name text, access_digest bytea, recovery_digest bytea, session_digest bytea
) RETURNS uuid
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    new_actor uuid := gen_random_uuid();
BEGIN
    INSERT INTO ductdelta.actor (id) VALUES (new_actor);
    INSERT INTO ductdelta.web_access_key (actor_id, display_name, key_digest, expires_at)
    VALUES (new_actor, ductdelta.setup_name(display_name), access_digest, 'infinity');
    INSERT INTO ductdelta.web_recovery_key (actor_id, key_digest)
    VALUES (new_actor, recovery_digest);
    PERFORM ductdelta.web_login(access_digest, session_digest);
    RETURN new_actor;
END;
$$;

CREATE FUNCTION ductdelta.web_recover_account(
    previous_recovery bytea, new_access bytea, new_recovery bytea, new_session bytea
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    recovered_actor uuid;
BEGIN
    DELETE FROM ductdelta.web_recovery_key WHERE key_digest = previous_recovery
    RETURNING actor_id INTO recovered_actor;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recovery key is unavailable' USING ERRCODE = '28000';
    END IF;

    UPDATE ductdelta.web_access_key
    SET key_digest = new_access, expires_at = 'infinity' WHERE actor_id = recovered_actor;
    DELETE FROM ductdelta.web_session WHERE actor_id = recovered_actor;
    INSERT INTO ductdelta.web_recovery_key (actor_id, key_digest) VALUES (recovered_actor, new_recovery);
    PERFORM ductdelta.web_login(new_access, new_session);
    RETURN recovered_actor;
END;
$$;

CREATE FUNCTION ductdelta.web_register_company(
    company_name text, display_name text, access_digest bytea, recovery_digest bytea, session_digest bytea
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    company_id uuid := gen_random_uuid();
    founder uuid;
BEGIN
    founder := ductdelta.setup_account(display_name, access_digest, recovery_digest, session_digest);
    INSERT INTO ductdelta.organization (id, name) VALUES (company_id, ductdelta.setup_name(company_name));
    INSERT INTO ductdelta.organization_member (organization_id, actor_id, role)
    VALUES (company_id, founder, 'admin');
    RETURN company_id;
END;
$$;

CREATE FUNCTION ductdelta.web_companies(requested_session bytea) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    authenticated_actor uuid := ductdelta.web_actor(requested_session);
BEGIN
    RETURN (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id', company.id, 'name', company.name, 'role', membership.role
        ) ORDER BY company.name, company.id), '[]'::jsonb)
        FROM ductdelta.organization_member AS membership
        JOIN ductdelta.organization AS company ON company.id = membership.organization_id
        WHERE membership.actor_id = authenticated_actor
    );
END;
$$;

CREATE FUNCTION ductdelta.company_admin(requested_session bytea, company_id uuid) RETURNS uuid
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
    RETURN authenticated_actor;
END;
$$;

CREATE FUNCTION ductdelta.lock_company_admin(requested_session bytea, company_id uuid) RETURNS uuid
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    -- Filter before locking, then recheck permission after competing writes finish.
    PERFORM ductdelta.company_admin(requested_session, company_id);
    PERFORM FROM ductdelta.organization WHERE id = company_id FOR UPDATE;
    RETURN ductdelta.company_admin(requested_session, company_id);
END;
$$;

CREATE FUNCTION ductdelta.web_company_projects(requested_session bytea, company_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM ductdelta.company_admin(requested_session, company_id);
    RETURN (
        SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name)
            ORDER BY name, id), '[]'::jsonb)
        FROM ductdelta.project WHERE organization_id = company_id
    );
END;
$$;

CREATE FUNCTION ductdelta.web_create_project(
    requested_session bytea, company_id uuid, project_id uuid, project_name text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    creator uuid := ductdelta.lock_company_admin(requested_session, company_id);
    cleaned_name text := ductdelta.setup_name(project_name);
BEGIN
    INSERT INTO ductdelta.project (id, organization_id, name) VALUES (project_id, company_id, cleaned_name)
    ON CONFLICT (id) DO NOTHING;
    IF FOUND THEN
        INSERT INTO ductdelta.project_member (organization_id, project_id, actor_id, permission)
        VALUES (company_id, project_id, creator, 'capture');
        INSERT INTO ductdelta.project_workflow_grant (organization_id, project_id, actor_id, capability)
        SELECT company_id, project_id, creator, capability
        FROM unnest(ARRAY['direction', 'commercial', 'finance']) AS capability;
    ELSE
        PERFORM FROM ductdelta.project AS project
        WHERE project.id = project_id AND organization_id = company_id AND name = cleaned_name;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Operation conflicts with an existing project' USING ERRCODE = 'DD001';
        END IF;
    END IF;
    RETURN jsonb_build_object('id', project_id, 'name', cleaned_name);
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ductdelta FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.web_register_company(text, text, bytea, bytea, bytea),
    ductdelta.web_recover_account(bytea, bytea, bytea, bytea), ductdelta.web_companies(bytea),
    ductdelta.web_company_projects(bytea, uuid), ductdelta.web_create_project(bytea, uuid, uuid, text)
TO ductdelta_web_runtime;

COMMIT;
