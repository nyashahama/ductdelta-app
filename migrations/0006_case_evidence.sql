BEGIN;

SET LOCAL ROLE ductdelta_owner;

CREATE TABLE ductdelta.case_file (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    project_id uuid NOT NULL,
    case_id uuid NOT NULL,
    actor_id uuid NOT NULL REFERENCES ductdelta.actor,
    operation_id uuid NOT NULL,
    filename text NOT NULL CHECK (char_length(filename) BETWEEN 1 AND 200),
    media_type text NOT NULL CHECK (media_type IN ('application/pdf', 'image/png', 'image/jpeg', 'text/plain')),
    caption text CHECK (char_length(caption) BETWEEN 1 AND 500),
    access_class text NOT NULL CHECK (access_class IN ('site', 'finance')),
    content bytea NOT NULL CHECK (octet_length(content) BETWEEN 1 AND 5242880),
    byte_size integer GENERATED ALWAYS AS (octet_length(content)) STORED,
    sha256 bytea GENERATED ALWAYS AS (sha256(content)) STORED,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (organization_id, project_id, case_id)
        REFERENCES ductdelta.change_case (organization_id, project_id, id),
    UNIQUE (case_id, actor_id, operation_id)
);

CREATE INDEX case_file_timeline ON ductdelta.case_file (case_id, recorded_at DESC, id DESC);

-- Keep the binary content and actor's operation key out of every metadata query.
CREATE VIEW ductdelta.case_file_metadata AS
SELECT id, case_id, filename, media_type, caption, access_class, byte_size, encode(sha256, 'hex') AS sha256,
    to_char(recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS recorded_at
FROM ductdelta.case_file;

CREATE FUNCTION ductdelta.case_validate_file(media_type text, content bytea) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    decoded text;
BEGIN
    CASE media_type
        WHEN 'application/pdf' THEN
            IF substring(content FROM 1 FOR 5) = decode('255044462d', 'hex') THEN
                RETURN;
            END IF;
        WHEN 'image/png' THEN
            IF substring(content FROM 1 FOR 8) = decode('89504e470d0a1a0a', 'hex') THEN
                RETURN;
            END IF;
        WHEN 'image/jpeg' THEN
            IF substring(content FROM 1 FOR 3) = decode('ffd8ff', 'hex') THEN
                RETURN;
            END IF;
        WHEN 'text/plain' THEN
            BEGIN
                decoded := convert_from(content, 'UTF8');
            EXCEPTION WHEN character_not_in_repertoire OR untranslatable_character THEN
                RAISE EXCEPTION 'Text evidence requires valid UTF-8' USING ERRCODE = '22023';
            END;
            IF translate(decoded, E'\r\n\t', '') !~ '[[:cntrl:]]'
               AND decoded !~ U&'[\0080-\009F]' THEN
                RETURN;
            END IF;
        ELSE NULL;
    END CASE;
    RAISE EXCEPTION 'Content does not match a supported evidence type' USING ERRCODE = '22023';
END;
$$;

CREATE FUNCTION ductdelta.web_attach_case_file(
    session_digest bytea, requested_project uuid, requested_case uuid, requested_operation uuid,
    requested_filename text, requested_media_type text, requested_content bytea,
    requested_caption text, requested_access_class text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, true);
    item ductdelta.change_case;
    saved ductdelta.case_file;
BEGIN
    IF member.permission <> 'capture' THEN
        RAISE EXCEPTION 'Capture permission required' USING ERRCODE = '42501';
    END IF;
    IF requested_access_class IS NULL OR requested_access_class NOT IN ('site', 'finance') THEN
        RAISE EXCEPTION 'Select an evidence access class' USING ERRCODE = '22023';
    END IF;
    IF requested_access_class = 'finance' THEN
        PERFORM FROM ductdelta.project_workflow_grant
        WHERE (organization_id, project_id, actor_id, capability) =
            (member.organization_id, member.project_id, member.actor_id, 'finance')
        FOR SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Finance grant required' USING ERRCODE = '42501';
        END IF;
    END IF;

    IF requested_operation IS NULL OR requested_filename IS NULL
       OR char_length(requested_filename) NOT BETWEEN 1 AND 200
       OR requested_filename <> btrim(requested_filename)
       OR requested_filename IN ('.', '..')
       OR requested_filename ~ '[[:cntrl:]]'
       OR requested_filename ~ U&'[\0080-\009F\202A-\202E\2066-\2069]'
       OR strpos(requested_filename, '/') > 0 OR strpos(requested_filename, chr(92)) > 0 THEN
        RAISE EXCEPTION 'Invalid evidence file name or operation' USING ERRCODE = '22023';
    END IF;
    IF requested_caption IS NOT NULL AND (requested_caption !~ '[^[:space:]]'
       OR char_length(requested_caption) > 500 OR requested_caption ~ '[[:cntrl:]]'
       OR requested_caption ~ U&'[\0080-\009F]') THEN
        RAISE EXCEPTION 'Invalid evidence caption' USING ERRCODE = '22023';
    END IF;
    IF requested_media_type IS NULL
       OR requested_media_type NOT IN ('application/pdf', 'image/png', 'image/jpeg', 'text/plain')
       OR requested_content IS NULL OR octet_length(requested_content) NOT BETWEEN 1 AND 5242880 THEN
        RAISE EXCEPTION 'Evidence requires a supported type and 1 byte to 5 MiB' USING ERRCODE = '22023';
    END IF;

    -- Share the workflow's case lock so closure and a new attachment cannot race.
    SELECT * INTO item FROM ductdelta.change_case
    WHERE (organization_id, project_id, id) = (member.organization_id, member.project_id, requested_case)
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Case unavailable' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO saved FROM ductdelta.case_file
    WHERE (case_id, actor_id, operation_id) = (item.id, member.actor_id, requested_operation);
    IF FOUND THEN
        IF (saved.filename, saved.media_type, saved.content, saved.caption, saved.access_class)
           IS DISTINCT FROM (requested_filename, requested_media_type, requested_content,
               requested_caption, requested_access_class) THEN
            RAISE EXCEPTION 'Operation ID already records different evidence' USING ERRCODE = 'DD001';
        END IF;
    ELSE
        IF item.closeout_id IS NOT NULL THEN
            RAISE EXCEPTION 'Case is closed' USING ERRCODE = '23514';
        END IF;
        PERFORM ductdelta.case_validate_file(requested_media_type, requested_content);
        INSERT INTO ductdelta.case_file (
            organization_id, project_id, case_id, actor_id, operation_id,
            filename, media_type, content, caption, access_class
        ) VALUES (
            member.organization_id, member.project_id, item.id, member.actor_id, requested_operation,
            requested_filename, requested_media_type, requested_content, requested_caption, requested_access_class
        ) RETURNING id INTO saved.id;
    END IF;

    RETURN (SELECT to_jsonb(metadata) - 'case_id' FROM ductdelta.case_file_metadata AS metadata
            WHERE id = saved.id);
END;
$$;

CREATE FUNCTION ductdelta.web_case_files(
    session_digest bytea, requested_project uuid, requested_case uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, false);
    result jsonb;
BEGIN
    PERFORM FROM ductdelta.change_case
    WHERE (organization_id, project_id, id) = (member.organization_id, member.project_id, requested_case);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Case unavailable' USING ERRCODE = '42501';
    END IF;
    SELECT coalesce(jsonb_agg(to_jsonb(metadata) - 'case_id'
        ORDER BY metadata.recorded_at DESC, metadata.id DESC), '[]'::jsonb) INTO result
    FROM ductdelta.case_file_metadata AS metadata
    WHERE metadata.case_id = requested_case AND (metadata.access_class = 'site' OR EXISTS (
        SELECT FROM ductdelta.project_workflow_grant
        WHERE (organization_id, project_id, actor_id, capability) =
              (member.organization_id, member.project_id, member.actor_id, 'finance')
    ));
    RETURN result;
END;
$$;

CREATE FUNCTION ductdelta.web_case_file(
    session_digest bytea, requested_project uuid, requested_case uuid, requested_file uuid
) RETURNS TABLE (filename text, media_type text, content bytea)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, false);
BEGIN
    RETURN QUERY
    SELECT file.filename, file.media_type, file.content
    FROM ductdelta.case_file AS file
    WHERE (file.organization_id, file.project_id, file.case_id, file.id) =
          (member.organization_id, member.project_id, requested_case, requested_file)
      AND (file.access_class = 'site' OR EXISTS (
          SELECT FROM ductdelta.project_workflow_grant
          WHERE (organization_id, project_id, actor_id, capability) =
                (member.organization_id, member.project_id, member.actor_id, 'finance')
      ));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Evidence unavailable' USING ERRCODE = '42501';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION ductdelta.case_validate_file(text, bytea),
    ductdelta.web_attach_case_file(bytea, uuid, uuid, uuid, text, text, bytea, text, text),
    ductdelta.web_case_files(bytea, uuid, uuid), ductdelta.web_case_file(bytea, uuid, uuid, uuid)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.web_attach_case_file(bytea, uuid, uuid, uuid, text, text, bytea, text, text),
    ductdelta.web_case_files(bytea, uuid, uuid), ductdelta.web_case_file(bytea, uuid, uuid, uuid)
    TO ductdelta_web_runtime;

COMMIT;
