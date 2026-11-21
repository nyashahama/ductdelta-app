//! Read-only HTTP endpoint for the scoped project overview.

use axum::extract::rejection::QueryRejection;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::{Json, Router, routing};
use serde::Deserialize;
use serde_json::Value;
use uuid::Uuid;

use crate::workspace::{Rejection, Reply, Workspace, session};

pub(crate) fn routes() -> Router<Workspace> {
    Router::new().route("/api/projects/{project}/overview", routing::get(load))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct OverviewQuery {
    days: Option<String>,
}

async fn load(
    State(workspace): State<Workspace>,
    Path(project): Path<Uuid>,
    query: Result<Query<OverviewQuery>, QueryRejection>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    let invalid_period = || Rejection::invalid("Choose a 7, 14 or 30 day range.");
    let Query(query) = query.map_err(|_| invalid_period())?;
    let days = match query.days.as_deref() {
        Some("7") => 7,
        None | Some("14") => 14,
        Some("30") => 30,
        Some(_) => return Err(invalid_period()),
    };
    let result = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_project_overview($1, $2, $3)",
                    &[&digest, &project, &days],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(result))
}
