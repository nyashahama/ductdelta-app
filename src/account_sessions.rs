//! Inventory and revocation for the authenticated account's browser sessions.

use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::{Json, Router, routing};
use serde_json::Value;
use uuid::Uuid;

use crate::workspace;
use crate::workspace::{Reply, Workspace};

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/api/account/sessions",
            routing::get(list).delete(revoke_others),
        )
        .route("/api/account/sessions/{id}", routing::delete(revoke_one))
}

async fn list(State(workspace): State<Workspace>, headers: HeaderMap) -> Reply<Json<Value>> {
    let digest = workspace::session(&headers)?;
    let sessions = workspace
        .query(move |database| {
            database
                .query_one("SELECT ductdelta.web_account_sessions($1)", &[&digest])?
                .try_get(0)
        })
        .await?;
    Ok(Json(sessions))
}

async fn revoke_one(
    State(workspace): State<Workspace>,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
) -> Reply<StatusCode> {
    revoke(workspace, headers, Some(id)).await
}

async fn revoke_others(
    State(workspace): State<Workspace>,
    headers: HeaderMap,
) -> Reply<StatusCode> {
    revoke(workspace, headers, None).await
}

async fn revoke(workspace: Workspace, headers: HeaderMap, id: Option<Uuid>) -> Reply<StatusCode> {
    let digest = workspace::session(&headers)?;
    workspace
        .query(move |database| {
            database.execute(
                "SELECT ductdelta.web_revoke_account_sessions($1, $2)",
                &[&digest, &id],
            )
        })
        .await?;
    Ok(StatusCode::NO_CONTENT)
}
