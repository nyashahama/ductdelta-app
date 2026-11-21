//! HTTP entry points for the protected change case commands.

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::{Json, Router, routing};
use serde::Deserialize;
use serde_json::Value;
use uuid::Uuid;

use crate::workspace::{Reply, Workspace, session};

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/api/projects/{project}/cases",
            routing::get(list).post(create),
        )
        .route("/api/projects/{project}/cases/{case}", routing::get(detail))
        .route(
            "/api/projects/{project}/cases/{case}/actions",
            routing::post(record_action),
        )
}

async fn list(
    State(workspace): State<Workspace>,
    Path(project): Path<Uuid>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    let result = workspace
        .query(move |database| {
            database
                .query_one("SELECT ductdelta.web_cases($1, $2)", &[&digest, &project])?
                .try_get(0)
        })
        .await?;
    Ok(Json(result))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CaseDraft {
    operation_id: Uuid,
    title: String,
    observation_id: Option<Uuid>,
}

async fn create(
    State(workspace): State<Workspace>,
    Path(project): Path<Uuid>,
    headers: HeaderMap,
    Json(input): Json<CaseDraft>,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    let result = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_create_case($1, $2, $3, $4, $5)",
                    &[
                        &digest,
                        &project,
                        &input.operation_id,
                        &input.title,
                        &input.observation_id,
                    ],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(result))
}

async fn detail(
    State(workspace): State<Workspace>,
    Path((project, case)): Path<(Uuid, Uuid)>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    let result = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_case($1, $2, $3)",
                    &[&digest, &project, &case],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(result))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Action {
    operation_id: Uuid,
    kind: String,
    data: Value,
}

async fn record_action(
    State(workspace): State<Workspace>,
    Path((project, case)): Path<(Uuid, Uuid)>,
    headers: HeaderMap,
    Json(input): Json<Action>,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    let result = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_case_action($1, $2, $3, $4, $5, $6)",
                    &[
                        &digest,
                        &project,
                        &case,
                        &input.operation_id,
                        &input.kind,
                        &input.data,
                    ],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(result))
}
