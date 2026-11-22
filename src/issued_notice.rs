//! Issue and retrieve immutable notice copies through scoped database commands.

use axum::extract::{Path, State};
use axum::http::{HeaderMap, HeaderName, StatusCode, header};
use axum::response::{Html, IntoResponse, Response};
use axum::{Json, Router, routing};
use serde::Deserialize;
use serde_json::Value;
use uuid::Uuid;

use crate::workspace::{Rejection, Reply, Workspace};
use crate::workspace::{key_digest, session, valid_key};

const COPIES: &str = "/api/projects/{project}/cases/{case}/notices/{notice}/copies";

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route(COPIES, routing::get(list).post(issue))
        .route(
            &format!("{COPIES}/{{copy}}/download"),
            routing::get(download),
        )
        .route(&format!("{COPIES}/{{copy}}/links"), routing::post(share))
        .route(
            &format!("{COPIES}/{{copy}}/links/{{link}}"),
            routing::delete(revoke),
        )
        .route("/api/notice-copy", routing::post(recipient_download))
        .route("/notice-copy", routing::get(recipient_page))
        .route("/notice-copy.js", routing::get(recipient_script))
        .route("/notice-copy.css", routing::get(recipient_style))
}

#[derive(Deserialize)]
struct NoticePath {
    project: Uuid,
    case: Uuid,
    notice: Uuid,
}

#[derive(Deserialize)]
struct CopyPath {
    project: Uuid,
    case: Uuid,
    notice: Uuid,
    copy: Uuid,
}

#[derive(Deserialize)]
struct LinkPath {
    project: Uuid,
    case: Uuid,
    notice: Uuid,
    copy: Uuid,
    link: Uuid,
}

async fn list(
    State(workspace): State<Workspace>,
    Path(path): Path<NoticePath>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    let result = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_issued_notice_copies($1, $2, $3, $4)",
                    &[&digest, &path.project, &path.case, &path.notice],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(result))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Draft {
    operation_id: Uuid,
    recipient: String,
    message: String,
    supersedes: Option<Uuid>,
}

async fn issue(
    State(workspace): State<Workspace>,
    Path(path): Path<NoticePath>,
    headers: HeaderMap,
    Json(draft): Json<Draft>,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    let result = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_issue_notice_copy($1, $2, $3, $4, $5, $6, $7, $8)",
                    &[
                        &digest,
                        &path.project,
                        &path.case,
                        &path.notice,
                        &draft.operation_id,
                        &draft.recipient,
                        &draft.message,
                        &draft.supersedes,
                    ],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(result))
}

async fn download(
    State(workspace): State<Workspace>,
    Path(path): Path<CopyPath>,
    headers: HeaderMap,
) -> Reply<Response> {
    let digest = session(&headers)?;
    let (version, bytes) = workspace
        .query(move |database| {
            let row = database.query_one(
                "SELECT version, bytes FROM ductdelta.web_issued_notice_copy($1, $2, $3, $4, $5)",
                &[&digest, &path.project, &path.case, &path.notice, &path.copy],
            )?;
            Ok((row.try_get(0)?, row.try_get(1)?))
        })
        .await?;
    Ok(attachment(version, bytes))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Share {
    operation_id: Uuid,
    token: String,
}

async fn share(
    State(workspace): State<Workspace>,
    Path(path): Path<CopyPath>,
    headers: HeaderMap,
    Json(input): Json<Share>,
) -> Reply<Json<Value>> {
    let session_digest = session(&headers)?;
    if !valid_key(&input.token) {
        return Err(Rejection::invalid("The recipient link is invalid."));
    }
    let digest = key_digest(&input.token);
    let result = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_share_notice_copy($1, $2, $3, $4, $5, $6, $7)",
                    &[
                        &session_digest,
                        &path.project,
                        &path.case,
                        &path.notice,
                        &path.copy,
                        &input.operation_id,
                        &digest,
                    ],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(result))
}

async fn revoke(
    State(workspace): State<Workspace>,
    Path(path): Path<LinkPath>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    let result = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_revoke_notice_copy_link($1, $2, $3, $4, $5, $6)",
                    &[
                        &digest,
                        &path.project,
                        &path.case,
                        &path.notice,
                        &path.copy,
                        &path.link,
                    ],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(result))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Recipient {
    token: String,
}

async fn recipient_download(
    State(workspace): State<Workspace>,
    Json(input): Json<Recipient>,
) -> Reply<Response> {
    if !valid_key(&input.token) {
        return Ok(StatusCode::NOT_FOUND.into_response());
    }
    let digest = key_digest(&input.token);
    let (version, bytes) = workspace
        .query(move |database| {
            let row = database.query_one(
                "SELECT version, bytes FROM ductdelta.web_recipient_notice_copy($1)",
                &[&digest],
            )?;
            Ok((row.try_get(0)?, row.try_get(1)?))
        })
        .await?;
    Ok(attachment(version, bytes))
}

fn attachment(version: i32, bytes: Vec<u8>) -> Response {
    (
        [
            (header::CONTENT_TYPE, "text/plain; charset=utf-8".to_owned()),
            (
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"notice-version-{version}.txt\""),
            ),
            (header::REFERRER_POLICY, "no-referrer".to_owned()),
        ],
        bytes,
    )
        .into_response()
}

async fn recipient_page() -> impl IntoResponse {
    (
        [
            (header::REFERRER_POLICY, "no-referrer"),
            (HeaderName::from_static("x-robots-tag"), "noindex, nofollow"),
        ],
        Html(include_str!("issued_notice_recipient.html")),
    )
}

async fn recipient_script() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
        include_str!("issued_notice_recipient.js"),
    )
}

async fn recipient_style() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
        include_str!("issued_notice_recipient.css"),
    )
}
