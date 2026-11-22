//! Company invitations and scoped access changes.

use axum::Json;
use axum::Router;
use axum::extract::Path;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::response::Response;
use axum::routing;
use serde::Deserialize;
use serde_json::Value;
use serde_json::json;
use uuid::Uuid;

use crate::company_setup;
use crate::company_setup::EnrollmentKeys;
use crate::invitation_mailer;
use crate::workspace;
use crate::workspace::Rejection;
use crate::workspace::Reply;
use crate::workspace::Workspace;

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/invitations/accept", routing::post(accept))
        .route("/api/companies/{company}/team", routing::get(team))
        .route(
            "/api/companies/{company}/invitations",
            routing::get(delivery_status).post(invite),
        )
        .route(
            "/api/companies/{company}/invitations/{id}",
            routing::delete(revoke_invitation),
        )
        .route(
            "/api/companies/{company}/members/{actor}",
            routing::put(change_role).delete(remove_member),
        )
        .route(
            "/api/companies/{company}/projects/{project}/members/{actor}",
            routing::put(change_project_access),
        )
}

async fn team(
    State(workspace): State<Workspace>,
    Path(company): Path<Uuid>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let session = workspace::session(&headers)?;
    let team = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_company_team($1, $2)",
                    &[&session, &company],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(team))
}

#[derive(Deserialize)]
struct Invitation {
    name: String,
    role: String,
    email: Option<String>,
    operation_id: Option<Uuid>,
}

async fn delivery_status(
    State(workspace): State<Workspace>,
    Path(company): Path<Uuid>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let session = workspace::session(&headers)?;
    let email_enabled = workspace.invitation_mailer().is_some();
    let deliveries: Value = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_invitation_email($1, $2)",
                    &[&session, &company],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(
        json!({ "email_enabled": email_enabled, "deliveries": deliveries }),
    ))
}

async fn invite(
    State(workspace): State<Workspace>,
    Path(company): Path<Uuid>,
    headers: HeaderMap,
    Json(draft): Json<Invitation>,
) -> Reply<(StatusCode, Json<Value>)> {
    let session = workspace::session(&headers)?;
    let name = company_setup::checked_name(&draft.name)?.to_owned();
    if let Some(email) = draft.email {
        let email = invitation_mailer::mailbox(&email)?;
        let operation_id = draft
            .operation_id
            .ok_or_else(|| Rejection::invalid("An email invitation requires an operation ID."))?;
        let mailer = workspace.invitation_mailer().ok_or_else(|| {
            Rejection::unavailable(
                "Invitation email is unavailable. Create a link to share privately.",
            )
        })?;
        let invitation_id = Uuid::new_v4();
        let digest = workspace::key_digest(&mailer.token(invitation_id));
        let sender = mailer.sender().to_owned();
        let origin = workspace.origin().to_owned();
        let invitation = workspace
            .query(move |database| {
                database
                    .query_one(
                        "SELECT ductdelta.web_queue_invitation($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
                        &[
                            &session, &company, &operation_id, &invitation_id, &name, &draft.role,
                            &digest, &email, &sender, &origin,
                        ],
                    )?
                    .try_get(0)
            })
            .await?;
        return Ok((StatusCode::ACCEPTED, Json(invitation)));
    }
    let token = workspace::random_key();
    let digest = workspace::key_digest(&token);
    let mut invitation: Value = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_invite($1, $2, $3, $4, $5)",
                    &[&session, &company, &name, &draft.role, &digest],
                )?
                .try_get(0)
        })
        .await?;
    invitation["token"] = json!(token);
    Ok((StatusCode::CREATED, Json(invitation)))
}

async fn revoke_invitation(
    State(workspace): State<Workspace>,
    Path((company, invitation)): Path<(Uuid, Uuid)>,
    headers: HeaderMap,
) -> Reply<StatusCode> {
    let session = workspace::session(&headers)?;
    workspace
        .query(move |database| {
            database.execute(
                "SELECT ductdelta.web_revoke_invite($1, $2, $3)",
                &[&session, &company, &invitation],
            )
        })
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct Accept {
    token: String,
    use_current_account: bool,
    recovery_key: Option<String>,
}

async fn accept(
    State(workspace): State<Workspace>,
    headers: HeaderMap,
    Json(input): Json<Accept>,
) -> Reply<Response> {
    if !workspace::valid_key(&input.token) {
        return Err(Rejection::invalid("The invitation code is invalid."));
    }
    let current = input
        .use_current_account
        .then(|| workspace::session(&headers))
        .transpose()?;
    let token = workspace::key_digest(&input.token);
    let keys = if input.use_current_account {
        None
    } else {
        Some(EnrollmentKeys::new(input.recovery_key.unwrap_or_default())?)
    };
    let (access, recovery, session) = keys.as_ref().map_or_else(
        || (None, None, None),
        |keys| {
            let (access, recovery, session) = keys.digests();
            (Some(access), Some(recovery), Some(session))
        },
    );
    let company = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_accept_invite($1, $2, $3, $4, $5)",
                    &[&token, &current, &access, &recovery, &session],
                )?
                .try_get(0)
        })
        .await?;
    match keys {
        Some(keys) => Ok(keys.response(&workspace, StatusCode::CREATED, company)),
        None => Ok((StatusCode::CREATED, Json(json!({ "id": company }))).into_response()),
    }
}

#[derive(Deserialize)]
struct RoleChange {
    role: String,
}

async fn change_role(
    State(workspace): State<Workspace>,
    Path((company, actor)): Path<(Uuid, Uuid)>,
    headers: HeaderMap,
    Json(input): Json<RoleChange>,
) -> Reply<StatusCode> {
    change_member(
        workspace,
        company,
        actor,
        workspace::session(&headers)?,
        Some(input.role),
    )
    .await
}

async fn remove_member(
    State(workspace): State<Workspace>,
    Path((company, actor)): Path<(Uuid, Uuid)>,
    headers: HeaderMap,
) -> Reply<StatusCode> {
    change_member(
        workspace,
        company,
        actor,
        workspace::session(&headers)?,
        None,
    )
    .await
}

async fn change_member(
    workspace: Workspace,
    company: Uuid,
    actor: Uuid,
    session: Vec<u8>,
    role: Option<String>,
) -> Reply<StatusCode> {
    workspace
        .query(move |database| {
            database.execute(
                "SELECT ductdelta.web_change_company_member($1, $2, $3, $4)",
                &[&session, &company, &actor, &role],
            )
        })
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct ProjectAccess {
    permission: Option<String>,
    capabilities: Vec<String>,
}

async fn change_project_access(
    State(workspace): State<Workspace>,
    Path((company, project, actor)): Path<(Uuid, Uuid, Uuid)>,
    headers: HeaderMap,
    Json(input): Json<ProjectAccess>,
) -> Reply<StatusCode> {
    let session = workspace::session(&headers)?;
    workspace
        .query(move |database| {
            database.execute(
                "SELECT ductdelta.web_change_project_access($1, $2, $3, $4, $5, $6)",
                &[
                    &session,
                    &company,
                    &project,
                    &actor,
                    &input.permission,
                    &input.capabilities,
                ],
            )
        })
        .await?;
    Ok(StatusCode::NO_CONTENT)
}
