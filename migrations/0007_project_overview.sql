BEGIN;

SET LOCAL ROLE ductdelta_owner;

CREATE INDEX case_event_overview_lookup ON ductdelta.case_event (case_id, kind, subject_id)
    WHERE kind IN ('instruction', 'notice', 'notice_dispatch');

CREATE FUNCTION ductdelta.web_project_overview(
    session_digest bytea, requested_project uuid, requested_days integer
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET timezone = 'UTC'
AS $$
DECLARE
    member ductdelta.project_member := ductdelta.case_member(session_digest, requested_project, false);
    today date := statement_timestamp()::date;
    first_day date;
BEGIN
    IF requested_days IS NULL OR requested_days NOT IN (7, 14, 30) THEN
        RAISE EXCEPTION 'Choose a 7, 14 or 30 day range' USING ERRCODE = '22023';
    END IF;
    first_day := today - requested_days + 1;

    RETURN (
        WITH project_cases AS NOT MATERIALIZED (
            SELECT id, title, recorded_at, closeout_id FROM ductdelta.change_case
            WHERE (organization_id, project_id) = (member.organization_id, member.project_id)
        ), open_cases AS (
            SELECT item.id, item.title, item.recorded_at, EXISTS (
                SELECT FROM ductdelta.case_event AS instruction
                WHERE instruction.case_id = item.id AND instruction.kind = 'instruction'
            ) AS has_instruction
            FROM project_cases AS item WHERE item.closeout_id IS NULL
        ), unsent_notices AS (
            SELECT notice.id, notice.case_id, item.title, notice.reference,
                (notice.data ->> 'due_at')::timestamptz AS due_at
            FROM open_cases AS item
            JOIN ductdelta.case_event AS notice ON notice.case_id = item.id
            WHERE notice.kind = 'notice' AND notice.data ? 'due_at'
              AND NOT EXISTS (
                  SELECT FROM ductdelta.case_event AS dispatch
                  WHERE (dispatch.case_id, dispatch.kind, dispatch.subject_id) =
                        (notice.case_id, 'notice_dispatch', notice.id)
              )
        ), notices_due AS (
            SELECT * FROM unsent_notices WHERE due_at < (today + 8)::timestamptz
        ), recent_cases AS (
            SELECT item.id, item.title, item.recorded_at, item.has_instruction,
                (SELECT min(notice.due_at) FROM unsent_notices AS notice WHERE notice.case_id = item.id)
                    AS notice_due_at
            FROM open_cases AS item ORDER BY item.recorded_at DESC, item.id DESC LIMIT 8
        ), recent_notices AS (
            SELECT case_id, title, reference, due_at
            FROM notices_due ORDER BY due_at, id LIMIT 5
        ), daily_observations AS (
            SELECT recorded_at::date AS day, count(*) AS total
            FROM ductdelta.observation
            WHERE (organization_id, project_id) = (member.organization_id, member.project_id)
              AND recorded_at >= first_day::timestamptz AND recorded_at < (today + 1)::timestamptz
            GROUP BY recorded_at::date
        ), daily_cases AS (
            SELECT recorded_at::date AS day, count(*) AS total FROM project_cases
            WHERE recorded_at >= first_day::timestamptz AND recorded_at < (today + 1)::timestamptz
            GROUP BY recorded_at::date
        ), activity AS (
            SELECT first_day + offsets.day_offset AS day,
                coalesce(observations.total, 0) AS observations, coalesce(cases.total, 0) AS cases
            FROM generate_series(0, requested_days - 1) AS offsets(day_offset)
            LEFT JOIN daily_observations AS observations ON observations.day = first_day + offsets.day_offset
            LEFT JOIN daily_cases AS cases ON cases.day = first_day + offsets.day_offset
        ), finance_access AS (
            SELECT EXISTS (
                SELECT FROM ductdelta.project_workflow_grant
                WHERE (organization_id, project_id, actor_id) =
                      (member.organization_id, member.project_id, member.actor_id)
                  AND capability IN ('commercial', 'finance')
            ) AS allowed
        )
        SELECT jsonb_build_object(
            'open_cases', (SELECT count(*) FROM open_cases),
            'without_instruction', (SELECT count(*) FROM open_cases WHERE NOT has_instruction),
            'notices_due', (SELECT count(*) FROM notices_due),
            'observations', (SELECT count(*) FROM ductdelta.observation
                WHERE (organization_id, project_id) = (member.organization_id, member.project_id)),
            'financial', CASE WHEN finance_access.allowed THEN (
                SELECT jsonb_build_object(
                    'outstanding', coalesce(sum(totals.outstanding), 0.00)::text,
                    'certified', coalesce(sum(totals.certified), 0.00)::text,
                    'matched', coalesce(sum(totals.matched), 0.00)::text,
                    'retained', coalesce(sum(totals.retained), 0.00)::text,
                    'currency', 'ZAR', 'basis', 'excl_vat'
                )
                FROM project_cases AS item
                CROSS JOIN LATERAL ductdelta.case_totals(item.id) AS totals
                WHERE EXISTS (SELECT FROM ductdelta.case_certificate WHERE case_id = item.id)
            ) END,
            'activity', (SELECT jsonb_agg(to_jsonb(activity) ORDER BY day) FROM activity),
            'cases', (SELECT coalesce(jsonb_agg(to_jsonb(recent_cases)
                ORDER BY recorded_at DESC, id DESC), '[]'::jsonb) FROM recent_cases),
            'notices', (SELECT coalesce(jsonb_agg(to_jsonb(recent_notices)
                ORDER BY due_at, case_id, reference), '[]'::jsonb) FROM recent_notices)
        )
        FROM finance_access
    );
END;
$$;

REVOKE ALL ON FUNCTION ductdelta.web_project_overview(bytea, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ductdelta.web_project_overview(bytea, uuid, integer) TO ductdelta_web_runtime;

COMMIT;
