BEGIN;

SET LOCAL ROLE ductdelta_owner;

CREATE TABLE ductdelta.invitation_email (
    invitation_id uuid PRIMARY KEY REFERENCES ductdelta.company_invitation,
    organization_id uuid NOT NULL REFERENCES ductdelta.organization,
    requested_by uuid NOT NULL REFERENCES ductdelta.actor,
    operation_id uuid NOT NULL,
    recipient text NOT NULL,
    sender text NOT NULL,
    origin text NOT NULL,
    company_name text NOT NULL,
    queued_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    next_attempt_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
    accepted_id uuid,
    needs_attention boolean NOT NULL DEFAULT false,
    UNIQUE (organization_id, requested_by, operation_id)
);

CREATE INDEX invitation_email_ready ON ductdelta.invitation_email (next_attempt_at)
    WHERE accepted_id IS NULL AND NOT needs_attention;
CREATE INDEX invitation_email_company_queue ON ductdelta.invitation_email (organization_id, queued_at DESC);

CREATE FUNCTION ductdelta.web_queue_invitation(
    requested_session bytea, company_id uuid, operation uuid, new_invitation uuid,
    invitee text, invited_role text, token_digest bytea, email text, sender text, origin text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    administrator uuid := ductdelta.lock_company_admin(requested_session, company_id);
    invitation ductdelta.company_invitation%ROWTYPE;
    previous_email text;
    invitee_name text := ductdelta.setup_name(invitee);
BEGIN
    SELECT saved.invitation_id, saved.recipient INTO invitation.id, previous_email
    FROM ductdelta.invitation_email AS saved
    WHERE (saved.organization_id, saved.requested_by, saved.operation_id) = (company_id, administrator, operation);

    IF FOUND THEN
        SELECT * INTO STRICT invitation FROM ductdelta.company_invitation WHERE id = invitation.id;
        IF (invitation.name, invitation.role, previous_email) IS DISTINCT FROM (invitee_name, invited_role, email) THEN
            RAISE EXCEPTION 'Invitation operation has different details' USING ERRCODE = 'DD001';
        END IF;
        RETURN jsonb_build_object('id', invitation.id, 'expires_at', invitation.expires_at);
    END IF;

    IF EXISTS (
        SELECT FROM ductdelta.invitation_email AS saved
        JOIN ductdelta.company_invitation AS pending ON pending.id = saved.invitation_id
        WHERE saved.organization_id = company_id AND lower(saved.recipient) = lower(email)
          AND pending.accepted_by IS NULL AND pending.revoked_at IS NULL
          AND pending.expires_at > statement_timestamp()
    ) THEN
        RAISE EXCEPTION 'An invitation to this email is already pending' USING ERRCODE = 'DD001';
    END IF;

    IF EXISTS (
        SELECT FROM ductdelta.invitation_email AS saved
        WHERE saved.organization_id = company_id AND saved.queued_at > statement_timestamp() - interval '1 hour'
        OFFSET 29
    ) THEN
        RAISE EXCEPTION 'Company invitation limit reached' USING ERRCODE = 'DD004';
    END IF;

    INSERT INTO ductdelta.company_invitation (id, organization_id, inviter_id, name, role, token_digest)
    VALUES (new_invitation, company_id, administrator, invitee_name, invited_role, token_digest)
    RETURNING * INTO invitation;
    INSERT INTO ductdelta.invitation_email (
        invitation_id, organization_id, requested_by, operation_id, recipient, sender, origin, company_name
    )
    SELECT invitation.id, company_id, administrator, operation, email, sender, origin, company.name
    FROM ductdelta.organization AS company WHERE company.id = company_id;
    RETURN jsonb_build_object('id', invitation.id, 'expires_at', invitation.expires_at);
END;
$$;

CREATE FUNCTION ductdelta.web_invitation_email(requested_session bytea, company_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM ductdelta.company_admin(requested_session, company_id);
    RETURN (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id', email.invitation_id, 'email', email.recipient, 'state', CASE
                WHEN email.accepted_id IS NOT NULL THEN 'accepted'
                WHEN email.needs_attention OR email.queued_at <= statement_timestamp() - interval '23 hours'
                    OR (email.attempts = 5 AND email.next_attempt_at <= statement_timestamp())
                    THEN 'needs_attention'
                ELSE 'queued'
            END
        ) ORDER BY email.queued_at DESC, email.invitation_id), '[]'::jsonb)
        FROM ductdelta.invitation_email AS email
        JOIN ductdelta.company_invitation AS invitation ON invitation.id = email.invitation_id
        WHERE email.organization_id = company_id AND invitation.accepted_by IS NULL
          AND invitation.revoked_at IS NULL AND invitation.expires_at > statement_timestamp()
    );
END;
$$;

CREATE FUNCTION ductdelta.claim_invitation_email()
RETURNS TABLE (
    id uuid, recipient text, sender text, origin text, company_name text, token_digest bytea, attempt integer
)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    WITH candidate AS (
        SELECT email.invitation_id, invitation.token_digest
        FROM ductdelta.invitation_email AS email
        JOIN ductdelta.company_invitation AS invitation ON invitation.id = email.invitation_id
        WHERE email.accepted_id IS NULL AND NOT email.needs_attention AND email.attempts < 5
          AND email.next_attempt_at <= statement_timestamp()
          AND email.queued_at > statement_timestamp() - interval '23 hours'
          AND invitation.accepted_by IS NULL AND invitation.revoked_at IS NULL
          AND invitation.expires_at > statement_timestamp()
        ORDER BY email.next_attempt_at, email.invitation_id
        LIMIT 1 FOR UPDATE OF email SKIP LOCKED
    )
    UPDATE ductdelta.invitation_email AS email
    SET attempts = email.attempts + 1, next_attempt_at = statement_timestamp() + interval '60 seconds'
    FROM candidate WHERE email.invitation_id = candidate.invitation_id
    RETURNING email.invitation_id, email.recipient, email.sender, email.origin, email.company_name,
              candidate.token_digest, email.attempts;
$$;

CREATE FUNCTION ductdelta.finish_invitation_email(
    requested_invitation uuid, current_attempt integer, provider_id uuid, retry_after integer
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    UPDATE ductdelta.invitation_email
    SET accepted_id = provider_id,
        needs_attention = provider_id IS NULL AND (retry_after IS NULL OR attempts >= 5),
        next_attempt_at = statement_timestamp() + make_interval(secs => greatest(retry_after, 0))
    WHERE invitation_id = requested_invitation AND attempts = current_attempt AND accepted_id IS NULL;
$$;

REVOKE ALL ON FUNCTION ductdelta.web_queue_invitation(bytea, uuid, uuid, uuid, text, text, bytea, text, text, text),
    ductdelta.web_invitation_email(bytea, uuid), ductdelta.claim_invitation_email(),
    ductdelta.finish_invitation_email(uuid, integer, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.web_queue_invitation(bytea, uuid, uuid, uuid, text, text, bytea, text, text, text),
    ductdelta.web_invitation_email(bytea, uuid), ductdelta.claim_invitation_email(),
    ductdelta.finish_invitation_email(uuid, integer, uuid, integer) TO ductdelta_web_runtime;

COMMIT;
