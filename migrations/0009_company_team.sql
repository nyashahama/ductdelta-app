BEGIN;

SET LOCAL ROLE ductdelta_owner;

CREATE TABLE ductdelta.company_invitation (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES ductdelta.organization,
    inviter_id uuid NOT NULL REFERENCES ductdelta.actor,
    name text NOT NULL,
    role text NOT NULL CHECK (role IN ('admin', 'member')),
    token_digest bytea NOT NULL UNIQUE CHECK (octet_length(token_digest) = 32),
    expires_at timestamptz NOT NULL DEFAULT (statement_timestamp() + interval '7 days'),
    revoked_at timestamptz,
    accepted_by uuid REFERENCES ductdelta.actor
);

CREATE INDEX company_invitation_pending ON ductdelta.company_invitation (organization_id)
    WHERE accepted_by IS NULL AND revoked_at IS NULL;

CREATE FUNCTION ductdelta.web_company_team(requested_session bytea, company_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    administrator uuid := ductdelta.company_admin(requested_session, company_id);
BEGIN
    RETURN jsonb_build_object(
        'actor_id', administrator,
        'members', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                'id', member.actor_id, 'name', coalesce(account.display_name, member.actor_id::text),
                'role', member.role
            ) ORDER BY account.display_name, member.actor_id), '[]'::jsonb)
            FROM ductdelta.organization_member AS member
            LEFT JOIN ductdelta.web_access_key AS account ON account.actor_id = member.actor_id
            WHERE member.organization_id = company_id
        ),
        'access', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                'project_id', member.project_id, 'actor_id', member.actor_id,
                'permission', member.permission, 'capabilities', ARRAY(
                    SELECT capability FROM ductdelta.project_workflow_grant
                    WHERE (organization_id, project_id, actor_id) =
                          (company_id, member.project_id, member.actor_id)
                    ORDER BY capability
                )
            ) ORDER BY member.project_id, member.actor_id), '[]'::jsonb)
            FROM ductdelta.project_member AS member WHERE member.organization_id = company_id
        ),
        'invitations', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                'id', id, 'name', name, 'role', role, 'expires_at', expires_at
            ) ORDER BY expires_at, id), '[]'::jsonb)
            FROM ductdelta.company_invitation
            WHERE organization_id = company_id AND accepted_by IS NULL AND revoked_at IS NULL
              AND expires_at > statement_timestamp()
        )
    );
END;
$$;

CREATE FUNCTION ductdelta.web_invite(
    requested_session bytea, company_id uuid, invitee text, invited_role text, token_digest bytea
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    administrator uuid := ductdelta.lock_company_admin(requested_session, company_id);
    invitation ductdelta.company_invitation%ROWTYPE;
BEGIN
    INSERT INTO ductdelta.company_invitation (organization_id, inviter_id, name, role, token_digest)
    VALUES (company_id, administrator, ductdelta.setup_name(invitee), invited_role, token_digest)
    RETURNING * INTO invitation;
    RETURN jsonb_build_object('id', invitation.id, 'expires_at', invitation.expires_at);
END;
$$;

CREATE FUNCTION ductdelta.web_revoke_invite(
    requested_session bytea, company_id uuid, invite_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM ductdelta.lock_company_admin(requested_session, company_id);
    UPDATE ductdelta.company_invitation SET revoked_at = statement_timestamp()
    WHERE organization_id = company_id AND id = invite_id AND accepted_by IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invitation unavailable' USING ERRCODE = '42501';
    END IF;
END;
$$;

CREATE FUNCTION ductdelta.web_accept_invite(
    requested_token bytea, current_session bytea, access_digest bytea,
    recovery_digest bytea, session_digest bytea
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    company_id uuid;
    invitation ductdelta.company_invitation%ROWTYPE;
    recipient uuid;
BEGIN
    SELECT organization_id INTO company_id FROM ductdelta.company_invitation
    WHERE token_digest = requested_token AND accepted_by IS NULL AND revoked_at IS NULL
      AND expires_at > clock_timestamp();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invitation unavailable' USING ERRCODE = '42501';
    END IF;

    PERFORM FROM ductdelta.organization WHERE id = company_id FOR UPDATE;
    SELECT * INTO invitation FROM ductdelta.company_invitation
    WHERE token_digest = requested_token AND accepted_by IS NULL AND revoked_at IS NULL
      AND expires_at > clock_timestamp();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invitation unavailable' USING ERRCODE = '42501';
    END IF;

    IF current_session IS NULL THEN
        recipient := ductdelta.setup_account(invitation.name, access_digest, recovery_digest, session_digest);
    ELSE
        recipient := ductdelta.web_actor(current_session);
    END IF;

    INSERT INTO ductdelta.organization_member (organization_id, actor_id, role)
    VALUES (company_id, recipient, invitation.role)
    ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'This account is already a company member' USING ERRCODE = 'DD001';
    END IF;
    UPDATE ductdelta.company_invitation SET accepted_by = recipient WHERE id = invitation.id;
    RETURN company_id;
END;
$$;

CREATE FUNCTION ductdelta.web_change_company_member(
    requested_session bytea, company_id uuid, member_id uuid, new_role text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    previous_role text;
BEGIN
    PERFORM ductdelta.lock_company_admin(requested_session, company_id);
    SELECT role INTO previous_role FROM ductdelta.organization_member
    WHERE organization_id = company_id AND actor_id = member_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Company member unavailable' USING ERRCODE = '42501';
    END IF;

    IF previous_role = 'admin' AND new_role IS DISTINCT FROM 'admin' THEN
        PERFORM FROM ductdelta.organization_member
        WHERE organization_id = company_id AND actor_id <> member_id AND role = 'admin';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'The company needs at least one administrator' USING ERRCODE = 'DD002';
        END IF;
        UPDATE ductdelta.company_invitation SET revoked_at = statement_timestamp()
        WHERE organization_id = company_id AND inviter_id = member_id
          AND accepted_by IS NULL AND revoked_at IS NULL;
    END IF;

    IF new_role IS NULL THEN
        DELETE FROM ductdelta.project_member WHERE organization_id = company_id AND actor_id = member_id;
        DELETE FROM ductdelta.organization_member WHERE organization_id = company_id AND actor_id = member_id;
    ELSE
        UPDATE ductdelta.organization_member SET role = new_role
        WHERE organization_id = company_id AND actor_id = member_id;
    END IF;
END;
$$;

CREATE FUNCTION ductdelta.web_change_project_access(
    requested_session bytea, company_id uuid, requested_project uuid, member_id uuid,
    new_permission text, new_capabilities text[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM ductdelta.lock_company_admin(requested_session, company_id);
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

    IF new_permission IS NULL THEN
        DELETE FROM ductdelta.project_member
        WHERE (organization_id, project_id, actor_id) = (company_id, requested_project, member_id);
        RETURN;
    END IF;

    INSERT INTO ductdelta.project_member (organization_id, project_id, actor_id, permission)
    VALUES (company_id, requested_project, member_id, new_permission)
    ON CONFLICT (organization_id, project_id, actor_id) DO UPDATE SET permission = excluded.permission;
    DELETE FROM ductdelta.project_workflow_grant
    WHERE (organization_id, project_id, actor_id) = (company_id, requested_project, member_id)
      AND capability <> ALL (new_capabilities);
    INSERT INTO ductdelta.project_workflow_grant (organization_id, project_id, actor_id, capability)
    SELECT company_id, requested_project, member_id, capability
    FROM unnest(new_capabilities) AS capability ON CONFLICT DO NOTHING;
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ductdelta FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.web_company_team(bytea, uuid),
    ductdelta.web_invite(bytea, uuid, text, text, bytea), ductdelta.web_revoke_invite(bytea, uuid, uuid),
    ductdelta.web_accept_invite(bytea, bytea, bytea, bytea, bytea),
    ductdelta.web_change_company_member(bytea, uuid, uuid, text),
    ductdelta.web_change_project_access(bytea, uuid, uuid, uuid, text, text[])
TO ductdelta_web_runtime;

COMMIT;
