BEGIN;

CREATE ROLE ductdelta_company_bootstrap NOLOGIN;
SET LOCAL ROLE ductdelta_owner;
GRANT USAGE ON SCHEMA ductdelta TO ductdelta_company_bootstrap;

CREATE TABLE ductdelta.first_company_admin (
    organization_id uuid PRIMARY KEY REFERENCES ductdelta.organization,
    actor_id uuid NOT NULL REFERENCES ductdelta.actor,
    appointed_by name NOT NULL,
    appointed_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

CREATE FUNCTION ductdelta.appoint_first_company_admin(company_id uuid, requested_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member_role text;
    appointed_actor uuid;
BEGIN
    PERFORM FROM ductdelta.organization WHERE id = company_id FOR UPDATE;
    SELECT role INTO member_role FROM ductdelta.organization_member
    WHERE organization_id = company_id AND actor_id = requested_actor;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Company member unavailable' USING ERRCODE = '42501';
    END IF;

    SELECT actor_id INTO appointed_actor FROM ductdelta.first_company_admin
    WHERE organization_id = company_id;
    IF appointed_actor = requested_actor AND member_role = 'admin' THEN
        RETURN;
    END IF;
    IF appointed_actor IS NOT NULL OR EXISTS (
        SELECT FROM ductdelta.organization_member WHERE organization_id = company_id AND role = 'admin'
    ) THEN
        RAISE EXCEPTION 'Company already has an administrator' USING ERRCODE = 'DD002';
    END IF;

    UPDATE ductdelta.organization_member SET role = 'admin'
    WHERE organization_id = company_id AND actor_id = requested_actor;
    INSERT INTO ductdelta.first_company_admin (organization_id, actor_id, appointed_by)
    VALUES (company_id, requested_actor, SESSION_USER);
END;
$$;

REVOKE ALL ON FUNCTION ductdelta.appoint_first_company_admin(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.appoint_first_company_admin(uuid, uuid) TO ductdelta_company_bootstrap;

COMMIT;
