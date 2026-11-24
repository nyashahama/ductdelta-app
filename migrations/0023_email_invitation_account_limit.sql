BEGIN;

SET LOCAL ROLE ductdelta_owner;

CREATE INDEX invitation_email_sender_queue ON ductdelta.invitation_email (requested_by, queued_at DESC);

CREATE FUNCTION ductdelta.limit_email_invites_per_account() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    -- Serialize sends by the same account across companies. The existing
    -- company limit is enforced when the invitation is queued.
    PERFORM pg_advisory_xact_lock(hashtextextended(NEW.requested_by::text, 746233));
    IF EXISTS (
        SELECT FROM ductdelta.invitation_email AS sent
        WHERE sent.requested_by = NEW.requested_by AND sent.queued_at > clock_timestamp() - interval '1 hour'
        OFFSET 29
    ) THEN
        RAISE EXCEPTION 'Account invitation limit reached' USING ERRCODE = 'DD004';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER invitation_email_account_limit
BEFORE INSERT ON ductdelta.invitation_email
FOR EACH ROW EXECUTE FUNCTION ductdelta.limit_email_invites_per_account();

REVOKE ALL ON FUNCTION ductdelta.limit_email_invites_per_account() FROM PUBLIC;

COMMIT;
