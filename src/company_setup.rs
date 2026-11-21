//! Company registration and project administration.

use axum::Json;
use axum::Router;
use axum::extract::Path;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::http::StatusCode;
use axum::http::header;
use axum::response::IntoResponse;
use axum::response::Response;
use axum::routing;
use serde::Deserialize;
use serde_json::Value;
use serde_json::json;
use uuid::Uuid;

use crate::workspace;
use crate::workspace::Rejection;
use crate::workspace::Reply;
use crate::workspace::Workspace;

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/companies", routing::get(companies).post(register))
        .route("/api/account/recover", routing::post(recover))
        .route(
            "/api/companies/{company}/projects",
            routing::get(projects).post(create_project),
        )
}

pub(crate) struct EnrollmentKeys {
    access: String,
    recovery: String,
    session: String,
}

impl EnrollmentKeys {
    pub(crate) fn new() -> Self {
        Self {
            access: workspace::random_key(),
            recovery: workspace::random_key(),
            session: workspace::random_key(),
        }
    }

    pub(crate) fn digests(&self) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        (
            workspace::key_digest(&self.access),
            workspace::key_digest(&self.recovery),
            workspace::key_digest(&self.session),
        )
    }

    pub(crate) fn response(self, workspace: &Workspace, status: StatusCode, id: Uuid) -> Response {
        (
            status,
            [(
                header::SET_COOKIE,
                workspace::session_cookie(workspace, &self.session, 43_200),
            )],
            Json(json!({ "id": id, "key": self.access, "recovery_key": self.recovery })),
        )
            .into_response()
    }
}

#[derive(Deserialize)]
struct CompanyDraft {
    company: String,
    name: String,
}

pub(crate) fn checked_name(name: &str) -> Reply<&str> {
    let name = name.trim();
    if !crate::observation::valid_text(name, 120) {
        return Err(Rejection::invalid("Enter a name of up to 120 characters."));
    }
    Ok(name)
}

async fn register(
    State(workspace): State<Workspace>,
    Json(draft): Json<CompanyDraft>,
) -> Reply<Response> {
    let company = checked_name(&draft.company)?.to_owned();
    let name = checked_name(&draft.name)?.to_owned();
    let keys = EnrollmentKeys::new();
    let (access, recovery, session) = keys.digests();
    let id = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_register_company($1, $2, $3, $4, $5)",
                    &[&company, &name, &access, &recovery, &session],
                )?
                .try_get(0)
        })
        .await?;
    Ok(keys.response(&workspace, StatusCode::CREATED, id))
}

#[derive(Deserialize)]
struct RecoveryRequest {
    recovery_key: String,
}

async fn recover(
    State(workspace): State<Workspace>,
    Json(input): Json<RecoveryRequest>,
) -> Reply<Response> {
    if !workspace::valid_key(&input.recovery_key) {
        return Err(Rejection::invalid("Enter a valid recovery key."));
    }
    let previous = workspace::key_digest(&input.recovery_key);
    let keys = EnrollmentKeys::new();
    let (access, recovery, session) = keys.digests();
    let actor = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_recover_account($1, $2, $3, $4)",
                    &[&previous, &access, &recovery, &session],
                )?
                .try_get(0)
        })
        .await?;
    Ok(keys.response(&workspace, StatusCode::OK, actor))
}

async fn companies(State(workspace): State<Workspace>, headers: HeaderMap) -> Reply<Json<Value>> {
    let session = workspace::session(&headers)?;
    let companies = workspace
        .query(move |database| {
            database
                .query_one("SELECT ductdelta.web_companies($1)", &[&session])?
                .try_get(0)
        })
        .await?;
    Ok(Json(companies))
}

async fn projects(
    State(workspace): State<Workspace>,
    Path(company): Path<Uuid>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let session = workspace::session(&headers)?;
    let projects = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_company_projects($1, $2)",
                    &[&session, &company],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(projects))
}

#[derive(Deserialize)]
struct ProjectDraft {
    name: String,
    operation_id: Uuid,
}

async fn create_project(
    State(workspace): State<Workspace>,
    Path(company): Path<Uuid>,
    headers: HeaderMap,
    Json(draft): Json<ProjectDraft>,
) -> Reply<(StatusCode, Json<Value>)> {
    let session = workspace::session(&headers)?;
    let name = checked_name(&draft.name)?.to_owned();
    let project = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_create_project($1, $2, $3, $4)",
                    &[&session, &company, &draft.operation_id, &name],
                )?
                .try_get(0)
        })
        .await?;
    Ok((StatusCode::CREATED, Json(project)))
}
