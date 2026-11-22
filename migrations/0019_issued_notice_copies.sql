BEGIN;

SET LOCAL ROLE ductdelta_owner;

CREATE TABLE ductdelta.issued_notice_copy (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id uuid NOT NULL,
    notice_id uuid NOT NULL,
    version integer NOT NULL CHECK (version > 0),
    supersedes uuid,
    issued_by uuid NOT NULL REFERENCES ductdelta.actor,
    operation_id uuid NOT NULL,
    issued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    recipient text NOT NULL,
    message text NOT NULL,
    bytes bytea NOT NULL,
    sha256 bytea GENERATED ALWAYS AS (sha256(bytes)) STORED,
    UNIQUE (case_id, notice_id, id),
    UNIQUE (notice_id, version),
    UNIQUE (notice_id, issued_by, operation_id),
    UNIQUE (supersedes),
    FOREIGN KEY (case_id, notice_id) REFERENCES ductdelta.case_event (case_id, id),
    FOREIGN KEY (case_id, notice_id, supersedes)
        REFERENCES ductdelta.issued_notice_copy (case_id, notice_id, id),
    CHECK ((supersedes IS NULL) = (version = 1))
);

CREATE TABLE ductdelta.issued_notice_link (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sequence bigint GENERATED ALWAYS AS IDENTITY,
    copy_id uuid NOT NULL REFERENCES ductdelta.issued_notice_copy,
    created_by uuid NOT NULL REFERENCES ductdelta.actor,
    operation_id uuid NOT NULL,
    token_digest bytea NOT NULL UNIQUE CHECK (octet_length(token_digest) = 32),
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    revoked_by uuid REFERENCES ductdelta.actor,
    UNIQUE (copy_id, created_by, operation_id),
    CHECK (expires_at > created_at),
    CHECK ((revoked_at IS NULL) = (revoked_by IS NULL))
);

CREATE INDEX issued_notice_link_latest ON ductdelta.issued_notice_link (copy_id, sequence DESC);

CREATE FUNCTION ductdelta.keep_issued_notice_copy() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'Issued notice copies are immutable' USING ERRCODE = '23514';
END;
$$;

CREATE TRIGGER keep_issued_notice_copy BEFORE UPDATE OR DELETE ON ductdelta.issued_notice_copy
FOR EACH ROW EXECUTE FUNCTION ductdelta.keep_issued_notice_copy();

-- Use the same case lock as workflow commands. It serializes issue, share and revoke
-- with one another and with closeout. Keep access checks in the database commands.
CREATE FUNCTION ductdelta.case_notice_source(
    session_digest bytea, requested_project uuid, requested_case uuid, requested_notice uuid,
    write_access boolean
) RETURNS ductdelta.case_event
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, write_access);
    notice ductdelta.case_event;
BEGIN
    IF write_access THEN
        IF member.permission <> 'capture' THEN
            RAISE EXCEPTION 'Capture permission required' USING ERRCODE = '42501';
        END IF;
        PERFORM FROM ductdelta.project_workflow_grant
        WHERE (organization_id, project_id, actor_id, capability) =
              (member.organization_id, member.project_id, member.actor_id, 'direction')
        FOR SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Direction grant required' USING ERRCODE = '42501';
        END IF;
        PERFORM FROM ductdelta.change_case
        WHERE (organization_id, project_id, id) = (member.organization_id, member.project_id, requested_case)
        FOR UPDATE;
    END IF;
    SELECT * INTO notice FROM ductdelta.case_event
    WHERE (organization_id, project_id, case_id, id, kind) =
          (member.organization_id, member.project_id, requested_case, requested_notice, 'notice');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Notice unavailable' USING ERRCODE = '42501';
    END IF;
    RETURN notice;
END;
$$;

CREATE FUNCTION ductdelta.issued_notice_metadata(copy ductdelta.issued_notice_copy)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'id', copy.id, 'version', copy.version, 'supersedes', copy.supersedes,
        'recipient', copy.recipient, 'issued_at', copy.issued_at, 'issued_by', copy.issued_by,
        'sha256', encode(copy.sha256, 'hex')
    );
$$;

CREATE FUNCTION ductdelta.issued_notice_link_metadata(link ductdelta.issued_notice_link)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'id', link.id, 'expires_at', link.expires_at, 'revoked_at', link.revoked_at
    );
$$;

CREATE FUNCTION ductdelta.issued_notice_header(value text)
RETURNS text LANGUAGE sql STABLE STRICT SET search_path = pg_catalog, pg_temp
AS $$
    -- Preserve historical values while preventing them from introducing another header.
    SELECT CASE WHEN value ~ '[[:cntrl:]]' THEN to_json(value)::text ELSE value END;
$$;

CREATE FUNCTION ductdelta.web_issue_notice_copy(
    session_digest bytea, requested_project uuid, requested_case uuid, requested_notice uuid,
    requested_operation uuid, requested_recipient text, requested_message text, previous_copy uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    notice ductdelta.case_event := ductdelta.case_notice_source(
        session_digest, requested_project, requested_case, requested_notice, true);
    issuer uuid := ductdelta.web_actor(session_digest);
    saved ductdelta.issued_notice_copy;
    previous ductdelta.issued_notice_copy;
    issued_at timestamptz;
    copy_id uuid;
    next_version integer;
    rule jsonb := notice.data -> 'notice_rule';
    rule_recipient text := rule ->> 'recipient';
    rule_issuer uuid := (rule ->> 'issuer_actor_id')::uuid;
    document text;
BEGIN
    IF rule_issuer IS NOT NULL AND rule_issuer <> issuer THEN
        RAISE EXCEPTION 'The notice must be issued by its recorded issuer' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO saved FROM ductdelta.issued_notice_copy
    WHERE (notice_id, issued_by, operation_id) = (notice.id, issuer, requested_operation);
    IF FOUND THEN
        IF (saved.recipient, saved.message, saved.supersedes)
           IS DISTINCT FROM (requested_recipient, requested_message, previous_copy) THEN
            RAISE EXCEPTION 'Operation ID already records a different copy' USING ERRCODE = 'DD001';
        END IF;
        RETURN ductdelta.issued_notice_metadata(saved);
    END IF;

    IF EXISTS (SELECT FROM ductdelta.change_case WHERE id = notice.case_id AND closeout_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Case is closed' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO previous FROM ductdelta.issued_notice_copy
    WHERE notice_id = notice.id ORDER BY version DESC LIMIT 1;
    IF previous.id IS DISTINCT FROM previous_copy THEN
        RAISE EXCEPTION 'The latest issued copy changed' USING ERRCODE = 'DD001';
    END IF;

    PERFORM ductdelta.case_text(jsonb_build_object('recipient', requested_recipient), 'recipient', 250);
    PERFORM ductdelta.case_text(jsonb_build_object('message', requested_message), 'message', 12000);
    IF requested_operation IS NULL
       OR (rule_recipient IS NOT NULL AND requested_recipient <> rule_recipient)
       OR requested_recipient ~ '[[:cntrl:]]'
       OR replace(replace(requested_message, chr(10), ''), chr(9), '') ~ '[[:cntrl:]]' THEN
        RAISE EXCEPTION 'Check the notice copy fields' USING ERRCODE = '22023';
    END IF;

    issued_at := clock_timestamp();
    copy_id := gen_random_uuid();
    next_version := coalesce(previous.version, 0) + 1;
    -- Build only from the selected notice fields and the text the issuer reviewed.
    document := concat(
        'Change notice', chr(10),
        'Reference: ', ductdelta.issued_notice_header(notice.reference), chr(10),
        'Agreement: ', ductdelta.issued_notice_header(notice.data ->> 'agreement'), chr(10),
        CASE WHEN rule ? 'clause' THEN
            concat('Clause: ', ductdelta.issued_notice_header(rule ->> 'clause'), chr(10)) END,
        CASE WHEN rule ? 'issuer_name' THEN
            concat('Issuer: ', ductdelta.issued_notice_header(rule ->> 'issuer_name'), chr(10)) END,
        'Recipient: ', requested_recipient, chr(10),
        CASE WHEN rule ? 'service_method' THEN
            concat('Service method: ', ductdelta.issued_notice_header(rule ->> 'service_method'), chr(10)) END,
        CASE WHEN notice.data ? 'due_at' THEN concat('Notice deadline: ', notice.data ->> 'due_at', chr(10)) END,
        'Copy ID: ', copy_id, chr(10),
        'Version: ', next_version, chr(10),
        CASE WHEN previous.id IS NOT NULL
             THEN concat('Supersedes copy: ', previous.id, ' (version ', previous.version, ')', chr(10)) END,
        'Issued at: ', to_char(issued_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), chr(10),
        chr(10), requested_message, chr(10)
    );
    INSERT INTO ductdelta.issued_notice_copy (
        id, case_id, notice_id, version, supersedes, issued_by, operation_id, issued_at, recipient, message, bytes
    ) VALUES (
        copy_id, notice.case_id, notice.id, next_version, previous_copy,
        issuer, requested_operation, issued_at, requested_recipient, requested_message, convert_to(document, 'UTF8')
    ) RETURNING * INTO saved;
    RETURN ductdelta.issued_notice_metadata(saved);
END;
$$;

CREATE FUNCTION ductdelta.web_issued_notice_copies(
    session_digest bytea, requested_project uuid, requested_case uuid, requested_notice uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    notice ductdelta.case_event := ductdelta.case_notice_source(
        session_digest, requested_project, requested_case, requested_notice, false);
BEGIN
    RETURN jsonb_build_object(
        'is_notice_issuer', coalesce((notice.data -> 'notice_rule' ->> 'issuer_actor_id')::uuid =
                                         ductdelta.web_actor(session_digest), true),
        'copies', (
            SELECT coalesce(jsonb_agg(ductdelta.issued_notice_metadata(copy) ||
                jsonb_build_object('link', (
                    SELECT ductdelta.issued_notice_link_metadata(link)
                    FROM ductdelta.issued_notice_link AS link WHERE link.copy_id = copy.id
                    ORDER BY link.sequence DESC LIMIT 1
                )) ORDER BY copy.version DESC), '[]'::jsonb)
            FROM ductdelta.issued_notice_copy AS copy WHERE copy.notice_id = notice.id
        )
    );
END;
$$;

CREATE FUNCTION ductdelta.web_issued_notice_copy(
    session_digest bytea, requested_project uuid, requested_case uuid, requested_notice uuid, requested_copy uuid
) RETURNS TABLE (version integer, bytes bytea)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    notice ductdelta.case_event := ductdelta.case_notice_source(
        session_digest, requested_project, requested_case, requested_notice, false);
BEGIN
    RETURN QUERY SELECT copy.version, copy.bytes FROM ductdelta.issued_notice_copy AS copy
    WHERE (copy.notice_id, copy.id) = (notice.id, requested_copy);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Notice copy unavailable' USING ERRCODE = '42501';
    END IF;
END;
$$;

CREATE FUNCTION ductdelta.web_share_notice_copy(
    session_digest bytea, requested_project uuid, requested_case uuid, requested_notice uuid, requested_copy uuid,
    requested_operation uuid, requested_digest bytea
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    notice ductdelta.case_event := ductdelta.case_notice_source(
        session_digest, requested_project, requested_case, requested_notice, true);
    issuer uuid := ductdelta.web_actor(session_digest);
    saved ductdelta.issued_notice_link;
    linked_at timestamptz := clock_timestamp();
BEGIN
    PERFORM FROM ductdelta.issued_notice_copy WHERE (notice_id, id) = (notice.id, requested_copy);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Notice copy unavailable' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO saved FROM ductdelta.issued_notice_link
    WHERE (copy_id, created_by, operation_id) = (requested_copy, issuer, requested_operation);
    IF FOUND THEN
        IF saved.token_digest IS DISTINCT FROM requested_digest THEN
            RAISE EXCEPTION 'Operation ID already records a different link' USING ERRCODE = 'DD001';
        END IF;
        RETURN ductdelta.issued_notice_link_metadata(saved);
    END IF;
    IF EXISTS (
        SELECT FROM ductdelta.issued_notice_link
        WHERE copy_id = requested_copy AND revoked_at IS NULL AND expires_at > linked_at
    ) THEN
        RAISE EXCEPTION 'Revoke the active recipient link before creating another' USING ERRCODE = 'DD001';
    END IF;
    INSERT INTO ductdelta.issued_notice_link (
        copy_id, created_by, operation_id, token_digest, created_at, expires_at
    ) VALUES (
        requested_copy, issuer, requested_operation, requested_digest, linked_at, linked_at + interval '168 hours'
    ) RETURNING * INTO saved;
    RETURN ductdelta.issued_notice_link_metadata(saved);
END;
$$;

CREATE FUNCTION ductdelta.web_revoke_notice_copy_link(
    session_digest bytea, requested_project uuid, requested_case uuid, requested_notice uuid, requested_copy uuid,
    requested_link uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    notice ductdelta.case_event := ductdelta.case_notice_source(
        session_digest, requested_project, requested_case, requested_notice, true);
    issuer uuid := ductdelta.web_actor(session_digest);
    saved ductdelta.issued_notice_link;
BEGIN
    SELECT link.* INTO saved FROM ductdelta.issued_notice_link AS link
    JOIN ductdelta.issued_notice_copy AS copy ON copy.id = link.copy_id
    WHERE (copy.notice_id, copy.id, link.id) = (notice.id, requested_copy, requested_link);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recipient link unavailable' USING ERRCODE = '42501';
    END IF;
    IF saved.revoked_at IS NULL THEN
        UPDATE ductdelta.issued_notice_link SET revoked_at = clock_timestamp(), revoked_by = issuer
        WHERE id = saved.id RETURNING * INTO saved;
    END IF;
    RETURN ductdelta.issued_notice_link_metadata(saved);
END;
$$;

CREATE FUNCTION ductdelta.web_recipient_notice_copy(requested_digest bytea)
RETURNS TABLE (version integer, bytes bytea)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN QUERY SELECT copy.version, copy.bytes FROM ductdelta.issued_notice_link AS link
    JOIN ductdelta.issued_notice_copy AS copy ON copy.id = link.copy_id
    WHERE link.token_digest = requested_digest AND link.revoked_at IS NULL
        AND link.expires_at > clock_timestamp();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recipient copy unavailable' USING ERRCODE = '42501';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION ductdelta.keep_issued_notice_copy(),
    ductdelta.case_notice_source(bytea, uuid, uuid, uuid, boolean),
    ductdelta.issued_notice_metadata(ductdelta.issued_notice_copy),
    ductdelta.issued_notice_link_metadata(ductdelta.issued_notice_link),
    ductdelta.issued_notice_header(text),
    ductdelta.web_issue_notice_copy(bytea, uuid, uuid, uuid, uuid, text, text, uuid),
    ductdelta.web_issued_notice_copies(bytea, uuid, uuid, uuid),
    ductdelta.web_issued_notice_copy(bytea, uuid, uuid, uuid, uuid),
    ductdelta.web_share_notice_copy(bytea, uuid, uuid, uuid, uuid, uuid, bytea),
    ductdelta.web_revoke_notice_copy_link(bytea, uuid, uuid, uuid, uuid, uuid),
    ductdelta.web_recipient_notice_copy(bytea)
    FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    ductdelta.web_issue_notice_copy(bytea, uuid, uuid, uuid, uuid, text, text, uuid),
    ductdelta.web_issued_notice_copies(bytea, uuid, uuid, uuid),
    ductdelta.web_issued_notice_copy(bytea, uuid, uuid, uuid, uuid),
    ductdelta.web_share_notice_copy(bytea, uuid, uuid, uuid, uuid, uuid, bytea),
    ductdelta.web_revoke_notice_copy_link(bytea, uuid, uuid, uuid, uuid, uuid),
    ductdelta.web_recipient_notice_copy(bytea)
    TO ductdelta_web_runtime;

COMMIT;
