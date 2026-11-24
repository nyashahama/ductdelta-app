BEGIN;

SET LOCAL ROLE ductdelta_owner;

ALTER TABLE ductdelta.web_access_key ADD COLUMN email text;
CREATE UNIQUE INDEX web_access_email ON ductdelta.web_access_key (lower(email));

CREATE TABLE ductdelta.email_recovery (
    actor_id uuid PRIMARY KEY REFERENCES ductdelta.actor,
    digest bytea NOT NULL UNIQUE CHECK (octet_length(digest) = 32)
);

CREATE TABLE ductdelta.email_code (
    id uuid PRIMARY KEY,
    delivery_id uuid NOT NULL UNIQUE,
    email text NOT NULL CHECK (char_length(email) <= 254),
    digest bytea NOT NULL CHECK (octet_length(digest) = 32),
    purpose text NOT NULL CHECK (purpose IN ('sign_in', 'company', 'invite', 'upgrade', 'recover')),
    actor_id uuid REFERENCES ductdelta.actor,
    legacy_digest bytea,
    invitation_id uuid REFERENCES ductdelta.company_invitation,
    company_name text,
    display_name text,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    expires_at timestamptz NOT NULL DEFAULT statement_timestamp() + interval '10 minutes',
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
    used_at timestamptz,
    notify_email text,
    next_send_at timestamptz DEFAULT statement_timestamp(),
    sends integer NOT NULL DEFAULT 0 CHECK (sends BETWEEN 0 AND 5)
);

CREATE INDEX email_code_created ON ductdelta.email_code (created_at);
CREATE INDEX email_code_mailbox ON ductdelta.email_code (lower(email), created_at);
CREATE INDEX email_code_invitation ON ductdelta.email_code (invitation_id, created_at);
CREATE INDEX email_code_ready ON ductdelta.email_code (next_send_at) WHERE next_send_at IS NOT NULL;

CREATE FUNCTION ductdelta.web_email_security(session_digest bytea) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object('email', access.email, 'has_recovery_code', recovery.actor_id IS NOT NULL)
    FROM ductdelta.web_access_key AS access
    LEFT JOIN ductdelta.email_recovery AS recovery USING (actor_id)
    WHERE access.actor_id = ductdelta.web_actor(session_digest)
$$;

CREATE FUNCTION ductdelta.web_rotate_email_recovery(session_digest bytea, new_digest bytea) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    account uuid := ductdelta.web_actor(session_digest);
BEGIN
    PERFORM FROM ductdelta.actor WHERE id = account FOR NO KEY UPDATE;
    PERFORM ductdelta.web_actor(session_digest);
    IF NOT EXISTS (
        SELECT FROM ductdelta.web_session AS session
        JOIN ductdelta.web_access_key AS access USING (actor_id)
        WHERE session.digest = session_digest AND session.created_at > clock_timestamp() - interval '10 minutes'
          AND access.email IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Fresh verified sign-in required' USING ERRCODE = 'DD008';
    END IF;
    INSERT INTO ductdelta.email_recovery (actor_id, digest) VALUES (account, new_digest)
    ON CONFLICT (actor_id) DO UPDATE SET digest = excluded.digest;
END;
$$;

CREATE OR REPLACE FUNCTION ductdelta.web_login(requested_key bytea, requested_session bytea) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    INSERT INTO ductdelta.web_session (digest, actor_id, key_digest, expires_at)
    SELECT requested_session, actor_id, key_digest,
           least(expires_at, statement_timestamp() + interval '12 hours')
    FROM ductdelta.web_access_key
    WHERE key_digest = requested_key AND expires_at > statement_timestamp() AND email IS NULL;
    RETURN FOUND;
END;
$$;

CREATE FUNCTION ductdelta.legacy_email_actor(proof bytea) RETURNS uuid
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp
AS $$
    SELECT access.actor_id
    FROM ductdelta.web_access_key AS access
    LEFT JOIN ductdelta.web_recovery_key AS recovery ON recovery.actor_id = access.actor_id
    WHERE access.email IS NULL AND (recovery.key_digest = proof OR
        (access.key_digest = proof AND access.expires_at > clock_timestamp()))
$$;

CREATE FUNCTION ductdelta.web_request_email_code(
    challenge_id uuid, new_delivery_id uuid, address text, code_digest bytea, intent text, company text,
    name text, invite_token bytea, legacy_proof bytea
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    prior ductdelta.email_code%ROWTYPE;
    account uuid;
    registered_account uuid;
    registered_mailbox text;
    invitation uuid;
    invited_mailbox text;
    delivery_address text;
    now_at timestamptz := clock_timestamp();
BEGIN
    -- Serialize idempotency and delivery limits across processes.
    PERFORM pg_advisory_xact_lock(746231, 1);
    SELECT actor_id, email INTO registered_account, registered_mailbox
    FROM ductdelta.web_access_key WHERE lower(email) = lower(address);

    CASE intent
        WHEN 'sign_in' THEN account := registered_account;
        WHEN 'company' THEN
            company := ductdelta.setup_name(company);
            name := ductdelta.setup_name(name);
        WHEN 'invite' THEN NULL;
        WHEN 'upgrade' THEN
            account := ductdelta.legacy_email_actor(legacy_proof);
            IF account IS NULL THEN
                RAISE EXCEPTION 'Legacy credential unavailable' USING ERRCODE = '28000';
            END IF;
        WHEN 'recover' THEN
            SELECT actor_id INTO account FROM ductdelta.email_recovery WHERE digest = legacy_proof;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Recovery code unavailable' USING ERRCODE = '28000';
            END IF;
        ELSE
            RAISE EXCEPTION 'Unknown email code purpose' USING ERRCODE = '22023';
    END CASE;

    IF intent = 'invite' OR (intent = 'upgrade' AND invite_token IS NOT NULL) THEN
        SELECT pending.id, sent.recipient INTO invitation, invited_mailbox
        FROM ductdelta.company_invitation AS pending
        LEFT JOIN ductdelta.invitation_email AS sent ON sent.invitation_id = pending.id
        WHERE pending.token_digest = invite_token AND pending.expires_at > now_at
          AND pending.accepted_by IS NULL AND pending.revoked_at IS NULL
          AND (sent.recipient IS NULL OR lower(sent.recipient) = lower(address));
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Invitation unavailable' USING ERRCODE = '42501';
        END IF;
    END IF;

    -- An existing account always receives codes at the mailbox it verified.
    -- An emailed invitation is bound to the mailbox used for its delivery.
    IF invited_mailbox IS NOT NULL AND registered_mailbox IS NOT NULL
       AND invited_mailbox <> registered_mailbox THEN
        RAISE EXCEPTION 'Invitation unavailable' USING ERRCODE = '42501';
    END IF;
    delivery_address := CASE WHEN intent = 'recover' THEN address
                             ELSE coalesce(invited_mailbox, registered_mailbox, address) END;
    IF intent = 'sign_in' THEN
        SELECT key_digest INTO legacy_proof FROM ductdelta.web_access_key WHERE actor_id = account;
    END IF;

    SELECT * INTO prior FROM ductdelta.email_code WHERE id = challenge_id;
    IF FOUND THEN
        IF (prior.email, prior.purpose, prior.actor_id, prior.legacy_digest,
            prior.invitation_id, prior.company_name, prior.display_name)
           IS DISTINCT FROM (delivery_address, intent, account, legacy_proof, invitation, company, name) THEN
            RAISE EXCEPTION 'Code request has different details' USING ERRCODE = 'DD001';
        END IF;
        RETURN;
    END IF;

    -- Public sign-in returns the same response for unknown and throttled requests.
    IF intent = 'sign_in' AND account IS NULL THEN
        RETURN;
    END IF;
    now_at := clock_timestamp();
    IF EXISTS (
           SELECT FROM ductdelta.email_code
           WHERE lower(email) = lower(address) AND purpose = intent AND used_at IS NULL
             AND created_at > now_at - interval '1 minute'
       )
       OR EXISTS (
           SELECT FROM ductdelta.email_code WHERE lower(email) = lower(address) AND created_at > now_at - interval '1 hour'
           OFFSET 4
       )
       OR EXISTS (
           SELECT FROM ductdelta.email_code
           WHERE invitation_id = invitation AND created_at > now_at - interval '1 hour'
           OFFSET 4
       )
       OR EXISTS (SELECT FROM ductdelta.email_code WHERE created_at > now_at - interval '1 minute' OFFSET 119) THEN
        RETURN;
    END IF;

    INSERT INTO ductdelta.email_code (
        id, delivery_id, email, digest, purpose, actor_id, legacy_digest, invitation_id, company_name, display_name
    ) VALUES (challenge_id, new_delivery_id, delivery_address, code_digest, intent, account, legacy_proof,
              invitation, company, name);
END;
$$;

CREATE FUNCTION ductdelta.web_verify_email_code(challenge_id uuid, proof bytea, session_digest bytea)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    challenge ductdelta.email_code%ROWTYPE;
    account uuid;
    registered_mailbox text;
    previous_mailbox text;
    invite_token bytea;
    account_name text;
BEGIN
    SELECT * INTO challenge FROM ductdelta.email_code WHERE id = challenge_id FOR UPDATE;
    IF NOT FOUND OR challenge.used_at IS NOT NULL OR challenge.expires_at <= clock_timestamp()
       OR challenge.attempts >= 5 THEN
        RETURN false;
    END IF;

    IF challenge.digest IS DISTINCT FROM proof THEN
        UPDATE ductdelta.email_code SET attempts = attempts + 1 WHERE id = challenge_id;
        RETURN false;
    END IF;

    -- Concurrent verification for the same address must resolve to one actor.
    PERFORM pg_advisory_xact_lock(hashtextextended(lower(challenge.email), 746231));
    IF challenge.expires_at <= clock_timestamp() THEN
        RETURN false;
    END IF;
    SELECT actor_id, email INTO account, registered_mailbox
    FROM ductdelta.web_access_key WHERE lower(email) = lower(challenge.email);
    IF challenge.purpose <> 'recover' AND account IS NOT NULL AND registered_mailbox <> challenge.email THEN
        RETURN false;
    END IF;
    IF challenge.purpose = 'sign_in' THEN
        PERFORM FROM ductdelta.web_access_key
        WHERE actor_id = challenge.actor_id AND email = challenge.email AND key_digest = challenge.legacy_digest FOR SHARE;
        IF NOT FOUND OR challenge.expires_at <= clock_timestamp() THEN
            RETURN false;
        END IF;
    END IF;

    IF challenge.purpose = 'recover' THEN
        IF account IS NOT NULL AND account <> challenge.actor_id THEN
            RAISE EXCEPTION 'Email already connected to an account' USING ERRCODE = 'DD001';
        END IF;
        account := challenge.actor_id;
        PERFORM FROM ductdelta.actor WHERE id = account FOR NO KEY UPDATE;
        SELECT email INTO STRICT previous_mailbox FROM ductdelta.web_access_key WHERE actor_id = account FOR UPDATE;
        IF challenge.expires_at <= clock_timestamp() THEN
            RETURN false;
        END IF;
        IF previous_mailbox = challenge.email THEN
            RAISE EXCEPTION 'Enter a different email address' USING ERRCODE = '22023';
        END IF;
        DELETE FROM ductdelta.email_recovery WHERE actor_id = account AND digest = challenge.legacy_digest;
        IF NOT FOUND THEN
            RETURN false;
        END IF;
        UPDATE ductdelta.web_access_key
        SET email = challenge.email, key_digest = sha256(uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()))
        WHERE actor_id = account;
        DELETE FROM ductdelta.web_session WHERE actor_id = account;
    ELSIF challenge.purpose = 'upgrade' THEN
        IF account IS NOT NULL THEN
            RAISE EXCEPTION 'Email already connected to an account' USING ERRCODE = 'DD001';
        END IF;
        PERFORM FROM ductdelta.web_access_key WHERE actor_id = challenge.actor_id AND email IS NULL FOR UPDATE;
        IF NOT FOUND OR challenge.expires_at <= clock_timestamp() THEN
            RETURN false;
        END IF;
        account := ductdelta.legacy_email_actor(challenge.legacy_digest);
        IF account IS DISTINCT FROM challenge.actor_id THEN
            RETURN false;
        END IF;
        UPDATE ductdelta.web_access_key
        SET email = challenge.email, key_digest = sha256(uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid())),
            expires_at = 'infinity'
        WHERE actor_id = account;
        DELETE FROM ductdelta.web_session WHERE actor_id = account;
        DELETE FROM ductdelta.web_recovery_key WHERE actor_id = account;
    END IF;

    IF challenge.invitation_id IS NOT NULL THEN
        SELECT invitation.token_digest, invitation.name INTO invite_token, account_name
        FROM ductdelta.company_invitation AS invitation WHERE invitation.id = challenge.invitation_id;
    ELSE
        account_name := challenge.display_name;
    END IF;

    IF account IS NULL THEN
        account := gen_random_uuid();
        INSERT INTO ductdelta.actor (id) VALUES (account);
        INSERT INTO ductdelta.web_access_key (actor_id, display_name, key_digest, expires_at, email)
        VALUES (account, account_name, sha256(uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid())),
                'infinity', challenge.email);
    END IF;

    INSERT INTO ductdelta.web_session (digest, actor_id, key_digest, expires_at)
    SELECT session_digest, actor_id, key_digest, clock_timestamp() + interval '12 hours'
    FROM ductdelta.web_access_key WHERE actor_id = account;
    IF challenge.purpose = 'company' THEN
        WITH company AS (
            INSERT INTO ductdelta.organization (id, name)
            VALUES (gen_random_uuid(), challenge.company_name) RETURNING id
        )
        INSERT INTO ductdelta.organization_member (organization_id, actor_id, role)
        SELECT id, account, 'admin' FROM company;
    ELSIF challenge.invitation_id IS NOT NULL THEN
        -- Recheck expiry and revocation with the existing invitation transaction.
        PERFORM ductdelta.web_accept_invite(invite_token, session_digest, NULL, NULL, NULL);
    END IF;

    UPDATE ductdelta.email_code
    SET used_at = clock_timestamp(), notify_email = previous_mailbox,
        next_send_at = CASE WHEN previous_mailbox IS NOT NULL THEN clock_timestamp() END,
        delivery_id = CASE WHEN previous_mailbox IS NULL THEN delivery_id ELSE gen_random_uuid() END,
        sends = CASE WHEN previous_mailbox IS NULL THEN sends ELSE 0 END
    WHERE id = challenge_id;
    RETURN true;
END;
$$;

CREATE FUNCTION ductdelta.claim_email_code()
RETURNS TABLE (id uuid, delivery_id uuid, email text, digest bytea, attempt integer, notification boolean)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    WITH expired AS (
        SELECT code.id FROM ductdelta.email_code AS code
        WHERE code.created_at <= statement_timestamp() - interval '1 hour'
        ORDER BY code.created_at LIMIT 100 FOR UPDATE SKIP LOCKED
    ), cleared AS (
        DELETE FROM ductdelta.email_code AS code USING expired WHERE code.id = expired.id
    ), candidate AS (
        SELECT code.id FROM ductdelta.email_code AS code
        WHERE code.next_send_at <= statement_timestamp() AND code.sends < 5
          AND (code.notify_email IS NOT NULL OR (code.expires_at > statement_timestamp() AND code.attempts < 5))
        ORDER BY code.next_send_at, code.id LIMIT 1 FOR UPDATE SKIP LOCKED
    )
    UPDATE ductdelta.email_code AS code
    SET next_send_at = statement_timestamp() + interval '20 seconds', sends = code.sends + 1
    FROM candidate WHERE code.id = candidate.id
    RETURNING code.id, code.delivery_id, coalesce(code.notify_email, code.email), code.digest,
        code.sends, code.notify_email IS NOT NULL
$$;

CREATE FUNCTION ductdelta.finish_email_code(challenge_id uuid, sent_delivery_id uuid, send_attempt integer, delay_seconds integer)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    UPDATE ductdelta.email_code
    SET next_send_at = statement_timestamp() + make_interval(secs => delay_seconds)
    WHERE id = challenge_id AND delivery_id = sent_delivery_id AND sends = send_attempt
      AND (used_at IS NULL OR notify_email IS NOT NULL)
$$;

REVOKE ALL ON FUNCTION ductdelta.legacy_email_actor(bytea),
    ductdelta.web_email_security(bytea), ductdelta.web_rotate_email_recovery(bytea,bytea),
    ductdelta.web_request_email_code(uuid,uuid,text,bytea,text,text,text,bytea,bytea),
    ductdelta.web_verify_email_code(uuid,bytea,bytea),
    ductdelta.claim_email_code(), ductdelta.finish_email_code(uuid,uuid,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.web_email_security(bytea), ductdelta.web_rotate_email_recovery(bytea,bytea),
    ductdelta.web_request_email_code(uuid,uuid,text,bytea,text,text,text,bytea,bytea),
    ductdelta.web_verify_email_code(uuid,bytea,bytea),
    ductdelta.claim_email_code(), ductdelta.finish_email_code(uuid,uuid,integer,integer) TO ductdelta_web_runtime;

COMMIT;
