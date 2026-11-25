BEGIN;

SET LOCAL ROLE ductdelta_owner;

CREATE FUNCTION ductdelta.web_project_follow_ups(
    session_digest bytea, requested_project uuid, requested_page integer
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET timezone = 'UTC'
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, false);
    page_size constant integer := 8;
BEGIN
    IF requested_page IS NULL OR requested_page < 1 THEN
        RAISE EXCEPTION 'Choose a positive page number' USING ERRCODE = '22023';
    END IF;

    RETURN (
        WITH access AS (
            SELECT coalesce(bool_or(capability IN ('commercial', 'finance')), false) AS financial,
                   coalesce(bool_or(capability = 'finance'), false) AS bank
            FROM ductdelta.project_workflow_grant
            WHERE (organization_id, project_id, actor_id) =
                  (member.organization_id, member.project_id, member.actor_id)
        ), candidates AS (
            SELECT item.id, item.title, item.observation_id, item.recorded_at, access.bank,
                   records.entries, pending.due_at, tasks.actions,
                   coalesce(tasks.priority, 4) AS priority
            FROM ductdelta.change_case AS item CROSS JOIN access
            CROSS JOIN LATERAL (
                SELECT coalesce(jsonb_object_agg(kind, jsonb_build_object(
                    'reference', reference, 'sequence', sequence, 'amount', data ->> 'amount'
                )), '{}'::jsonb) AS entries
                FROM (
                    SELECT DISTINCT ON (kind) kind, reference, sequence, data
                    FROM ductdelta.case_event
                    WHERE case_id = item.id AND (kind = 'instruction' OR
                        (access.financial AND kind IN ('quote', 'application', 'certificate')))
                    ORDER BY kind, sequence DESC
                ) AS latest
            ) AS records
            LEFT JOIN LATERAL (
                SELECT notice.reference, CASE WHEN NOT service.has_dispatch
                           THEN (notice.data ->> 'due_at')::timestamptz END AS due_at,
                       notice.id, copy.id AS copy_id, copy.version, service.has_dispatch
                FROM ductdelta.case_event AS notice
                LEFT JOIN LATERAL (
                    SELECT id, version FROM ductdelta.issued_notice_copy
                    WHERE notice_id = notice.id ORDER BY version DESC LIMIT 1
                ) AS copy ON true
                CROSS JOIN LATERAL (
                    SELECT count(*) > 0 AS has_dispatch,
                           coalesce(bool_or(dispatch.data -> 'copy' ->> 'id' = copy.id::text), false) AS latest_sent
                    FROM ductdelta.case_event AS dispatch
                    WHERE (dispatch.case_id, dispatch.kind, dispatch.subject_id) =
                          (notice.case_id, 'notice_dispatch', notice.id)
                ) AS service
                WHERE notice.case_id = item.id AND notice.kind = 'notice'
                  AND NOT (service.has_dispatch AND (copy.id IS NULL OR service.latest_sent))
                ORDER BY due_at NULLS LAST, notice.sequence LIMIT 1
            ) AS pending ON true
            LEFT JOIN LATERAL ductdelta.case_totals(item.id) AS totals ON access.financial
            CROSS JOIN LATERAL (
                SELECT jsonb_agg(jsonb_build_object(
                    'kind', kind, 'amount', amount::text, 'reference', reference, 'count', line_count,
                    'due_at', due_at, 'notice_id', notice_id, 'copy_id', copy_id, 'version', version
                ) ORDER BY position) AS actions, min(priority) AS priority
                FROM (VALUES
                    (1, CASE WHEN pending.due_at < (statement_timestamp()::date + 8)::timestamptz THEN 0 ELSE 3 END,
                        CASE WHEN pending.has_dispatch THEN 'revised_notice' ELSE 'notice' END,
                        pending.id IS NOT NULL, NULL, pending.reference,
                        NULL, pending.due_at, pending.id, pending.copy_id, pending.version),
                    (2, 3, 'instruction', NOT records.entries ? 'instruction', NULL, NULL,
                        NULL, NULL, NULL, NULL, NULL),
                    (3, 3, 'quote', access.financial AND records.entries ? 'instruction'
                            AND NOT records.entries ?| ARRAY['quote', 'application', 'certificate'],
                        NULL, NULL, NULL, NULL, NULL, NULL, NULL),
                    (4, 2, 'quote_decision', totals.quote_awaiting_decision,
                        totals.proposed, records.entries -> 'quote' ->> 'reference', NULL, NULL, NULL, NULL, NULL),
                    (5, 2, 'quote_lines', totals.unresolved_lines > 0, NULL, NULL,
                        totals.unresolved_lines, NULL, NULL, NULL, NULL),
                    (6, 1, 'uncertified', totals.agreed > 0 AND totals.agreed > totals.certified,
                        totals.agreed - totals.certified, records.entries -> 'application' ->> 'reference',
                        NULL, NULL, NULL, NULL, NULL),
                    (7, 1, 'application', access.financial
                            AND NOT coalesce(totals.agreed > 0 AND totals.agreed > totals.certified, false)
                            AND (records.entries -> 'application' ->> 'amount')::numeric > 0
                            AND (records.entries -> 'application' ->> 'sequence')::bigint >
                                coalesce((records.entries -> 'certificate' ->> 'sequence')::bigint, 0),
                        NULL, records.entries -> 'application' ->> 'reference', NULL, NULL, NULL, NULL, NULL),
                    (8, 1, 'unallocated', access.bank AND totals.unallocated > 0, totals.unallocated,
                        NULL, NULL, NULL, NULL, NULL, NULL),
                    (9, 1, 'collect', totals.outstanding > 0, totals.outstanding,
                        NULL, NULL, NULL, NULL, NULL, NULL),
                    (10, 1, 'credit', totals.outstanding < 0, -totals.outstanding,
                        NULL, NULL, NULL, NULL, NULL, NULL),
                    (11, 2, 'retention', totals.retained > 0, totals.retained,
                        NULL, NULL, NULL, NULL, NULL, NULL)
                ) AS task(position, priority, kind, required, amount, reference, line_count,
                          due_at, notice_id, copy_id, version)
                WHERE required
            ) AS tasks
            WHERE (item.organization_id, item.project_id) = (member.organization_id, member.project_id)
              AND item.closeout_id IS NULL
        ), page AS MATERIALIZED (
            SELECT *, row_number() OVER (ORDER BY priority,
                CASE WHEN priority = 0 THEN due_at END, recorded_at, id) AS position
            FROM candidates
            ORDER BY position LIMIT page_size + 1 OFFSET (requested_page::bigint - 1) * page_size
        ), display AS (
            SELECT * FROM page ORDER BY position LIMIT page_size
        )
        SELECT jsonb_build_object('has_more', (SELECT count(*) > page_size FROM page), 'cases', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                'id', item.id, 'title', item.title,
                'actions', coalesce(item.actions, '[{"kind":"review"}]'::jsonb),
                'evidence', jsonb_build_object(
                    'observation_id', item.observation_id,
                    'references', coalesce((
                        SELECT jsonb_agg(jsonb_build_object('kind', kinds.kind,
                            'reference', item.entries -> kinds.kind ->> 'reference') ORDER BY kinds.position)
                        FROM (VALUES (1, 'instruction'), (2, 'quote'), (3, 'application'), (4, 'certificate'))
                            AS kinds(position, kind)
                        WHERE item.entries ? kinds.kind
                    ), '[]'::jsonb),
                    'unpaid_certificates', CASE WHEN item.actions @> '[{"kind":"collect"}]'::jsonb THEN (
                        SELECT coalesce(jsonb_agg(reference ORDER BY sequence), '[]'::jsonb)
                        FROM (
                            SELECT event.reference, event.sequence
                            FROM ductdelta.case_certificate_balances(item.id) AS balance
                            JOIN ductdelta.case_event AS event ON (event.case_id, event.id) =
                                (item.id, balance.certificate_id)
                            WHERE balance.available > 0 ORDER BY event.sequence LIMIT 3
                        ) AS unpaid
                    ) ELSE '[]'::jsonb END,
                    'file_count', files.total, 'files', files.entries
                )
            ) ORDER BY item.position)
            FROM display AS item
            CROSS JOIN LATERAL (
                SELECT coalesce(max(total), 0) AS total, coalesce(jsonb_agg(jsonb_build_object(
                    'id', id, 'filename', filename, 'access_class', access_class
                ) ORDER BY recorded_at DESC, id DESC), '[]'::jsonb) AS entries
                FROM (
                    SELECT id, filename, access_class, recorded_at, count(*) OVER () AS total
                    FROM ductdelta.case_file_metadata
                    WHERE case_id = item.id AND (access_class = 'site' OR item.bank)
                    ORDER BY recorded_at DESC, id DESC LIMIT 3
                ) AS visible
            ) AS files
        ), '[]'::jsonb))
    );
END;
$$;

REVOKE ALL ON FUNCTION ductdelta.web_project_follow_ups(bytea, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.web_project_follow_ups(bytea, uuid, integer) TO ductdelta_web_runtime;

COMMIT;
