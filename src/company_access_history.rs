//! Company administrator invitation settings and access history.

use axum::Json;
use axum::Router;
use axum::extract::Path;
use axum::extract::Query;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::routing;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

use crate::workspace;
use crate::workspace::Reply;
use crate::workspace::Workspace;

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/api/companies/{company}/invitation-lifetime",
            routing::get(invitation_lifetime).put(set_invitation_lifetime),
        )
        .route(
            "/api/companies/{company}/access-history",
            routing::get(access_history),
        )
}

#[derive(Deserialize, Serialize)]
struct InvitationLifetime {
    days: i32,
}

async fn invitation_lifetime(
    State(workspace): State<Workspace>,
    Path(company): Path<Uuid>,
    headers: HeaderMap,
) -> Reply<Json<InvitationLifetime>> {
    let session = workspace::session(&headers)?;
    let days = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_invitation_lifetime($1, $2)",
                    &[&session, &company],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(InvitationLifetime { days }))
}

async fn set_invitation_lifetime(
    State(workspace): State<Workspace>,
    Path(company): Path<Uuid>,
    headers: HeaderMap,
    Json(input): Json<InvitationLifetime>,
) -> Reply<Json<InvitationLifetime>> {
    let session = workspace::session(&headers)?;
    let days = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_set_invitation_lifetime($1, $2, $3)",
                    &[&session, &company, &input.days],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(InvitationLifetime { days }))
}

#[derive(Deserialize)]
struct HistoryPage {
    before: Option<Uuid>,
}

async fn access_history(
    State(workspace): State<Workspace>,
    Path(company): Path<Uuid>,
    Query(page): Query<HistoryPage>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let session = workspace::session(&headers)?;
    let history = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_company_access_history($1, $2, $3)",
                    &[&session, &company, &page.before],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(history))
}
