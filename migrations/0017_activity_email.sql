BEGIN;

SET LOCAL ROLE ductdelta_owner;

CREATE TABLE ductdelta.activity_email_settings (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    recipient text NOT NULL CHECK (length(recipient) BETWEEN 3 AND 254),
    sender text NOT NULL CHECK (length(sender) BETWEEN 3 AND 254)
);

CREATE TABLE ductdelta.activity_email (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind text NOT NULL CHECK (kind IN (
        'signup', 'invitation_accepted', 'project_created', 'change_opened',
        'instruction', 'decision', 'certificate', 'receipt', 'close'
    )),
    recipient text NOT NULL,
    sender text NOT NULL,
    queued_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    next_attempt_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
    accepted_id uuid,
    needs_attention boolean NOT NULL DEFAULT false
);

CREATE INDEX activity_email_ready ON ductdelta.activity_email (next_attempt_at)
    WHERE accepted_id IS NULL AND NOT needs_attention;

CREATE FUNCTION ductdelta.queue_activity_email() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    event_kind text;
BEGIN
    IF TG_NARGS = 0 THEN
        event_kind := NEW.kind;
    ELSE
        event_kind := TG_ARGV[0];
    END IF;
    INSERT INTO ductdelta.activity_email (kind, recipient, sender)
    SELECT event_kind, settings.recipient, settings.sender
    FROM ductdelta.activity_email_settings AS settings;
    RETURN NULL;
END;
$$;

CREATE TRIGGER activity_email_signup AFTER INSERT ON ductdelta.organization
FOR EACH ROW EXECUTE FUNCTION ductdelta.queue_activity_email('signup');

CREATE TRIGGER activity_email_invitation AFTER UPDATE OF accepted_by ON ductdelta.company_invitation
FOR EACH ROW WHEN (OLD.accepted_by IS NULL AND NEW.accepted_by IS NOT NULL)
EXECUTE FUNCTION ductdelta.queue_activity_email('invitation_accepted');

CREATE TRIGGER activity_email_project AFTER INSERT ON ductdelta.project
FOR EACH ROW EXECUTE FUNCTION ductdelta.queue_activity_email('project_created');

CREATE TRIGGER activity_email_case AFTER INSERT ON ductdelta.change_case
FOR EACH ROW EXECUTE FUNCTION ductdelta.queue_activity_email('change_opened');

CREATE TRIGGER activity_email_case_event AFTER INSERT ON ductdelta.case_event
FOR EACH ROW WHEN (NEW.kind IN ('instruction', 'decision', 'certificate', 'receipt', 'close'))
EXECUTE FUNCTION ductdelta.queue_activity_email();

CREATE FUNCTION ductdelta.claim_activity_email()
RETURNS TABLE (id uuid, kind text, recipient text, sender text, occurred_at text, attempt integer)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    WITH candidate AS (
        SELECT email.id
        FROM ductdelta.activity_email AS email
        JOIN ductdelta.activity_email_settings AS settings
          ON (settings.recipient, settings.sender) = (email.recipient, email.sender)
        WHERE email.accepted_id IS NULL AND NOT email.needs_attention AND email.attempts < 5
          AND email.next_attempt_at <= statement_timestamp()
          AND email.queued_at > statement_timestamp() - interval '23 hours'
        ORDER BY email.next_attempt_at, email.id
        LIMIT 1 FOR UPDATE OF email SKIP LOCKED
    )
    UPDATE ductdelta.activity_email AS email
    SET attempts = email.attempts + 1, next_attempt_at = statement_timestamp() + interval '60 seconds'
    FROM candidate WHERE email.id = candidate.id
    RETURNING email.id, email.kind, email.recipient, email.sender,
              to_char(email.queued_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS "UTC"'), email.attempts;
$$;

CREATE FUNCTION ductdelta.finish_activity_email(requested_id uuid, current_attempt integer,
    provider_id uuid, retry_after integer) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
    UPDATE ductdelta.activity_email
    SET accepted_id = provider_id,
        needs_attention = provider_id IS NULL AND (retry_after IS NULL OR attempts >= 5),
        next_attempt_at = statement_timestamp() + make_interval(secs => greatest(retry_after, 0))
    WHERE id = requested_id AND attempts = current_attempt AND accepted_id IS NULL;
$$;

REVOKE ALL ON FUNCTION ductdelta.queue_activity_email(), ductdelta.claim_activity_email(),
    ductdelta.finish_activity_email(uuid, integer, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.claim_activity_email(),
    ductdelta.finish_activity_email(uuid, integer, uuid, integer) TO ductdelta_web_runtime;

COMMIT;
