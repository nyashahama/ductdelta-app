//! Project-scoped notice rule HTTP endpoints.

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::{Json, Router, routing};
use serde::Deserialize;
use serde_json::Value;
use uuid::Uuid;

use crate::workspace::{Reply, Workspace, session};

pub(crate) fn routes() -> Router<Workspace> {
    Router::new().route(
        "/api/projects/{project}/notice-rule",
        routing::get(current).post(publish),
    )
}

async fn current(
    State(workspace): State<Workspace>,
    Path(project): Path<Uuid>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    let result = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_project_notice_rule($1, $2)",
                    &[&digest, &project],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(result))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NewRule {
    operation_id: Uuid,
    expected_version: i32,
    rule: Value,
}

async fn publish(
    State(workspace): State<Workspace>,
    Path(project): Path<Uuid>,
    headers: HeaderMap,
    Json(input): Json<NewRule>,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    let result = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_publish_notice_rule($1, $2, $3, $4, $5)",
                    &[
                        &digest,
                        &project,
                        &input.operation_id,
                        &input.expected_version,
                        &input.rule,
                    ],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(result))
}
