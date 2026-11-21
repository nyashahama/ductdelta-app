//! Upload and download original case files through the protected SQL commands.

use std::fmt::Write;

use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{HeaderMap, header};
use axum::response::IntoResponse;
use axum::{Json, Router, routing};
use serde_json::Value;
use uuid::Uuid;

use crate::workspace::{Rejection, Reply, Workspace, session};

const MAX_BYTES: usize = 5 * 1024 * 1024;

pub(crate) fn routes() -> Router<Workspace> {
    let uploads = routing::post(upload).layer(DefaultBodyLimit::max(MAX_BYTES));
    Router::new()
        .route(
            "/api/projects/{project}/cases/{case}/files",
            routing::get(list).merge(uploads),
        )
        .route(
            "/api/projects/{project}/cases/{case}/files/{file}",
            routing::get(download),
        )
}

async fn list(
    State(workspace): State<Workspace>,
    Path((project, case)): Path<(Uuid, Uuid)>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    let files = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_case_files($1, $2, $3)",
                    &[&digest, &project, &case],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(files))
}

fn field<'a>(headers: &'a HeaderMap, name: &str) -> Reply<&'a str> {
    let value = headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| Rejection::invalid("The file request is missing required details."))?;
    Ok(value)
}

fn decode(value: &str) -> Reply<String> {
    let invalid = || Rejection::invalid("Check the file name or caption.");
    let mut bytes = Vec::with_capacity(value.len());
    let mut input = value.bytes();
    while let Some(byte) = input.next() {
        if byte != b'%' {
            bytes.push(byte);
            continue;
        }
        let first = input.next().and_then(|byte| char::from(byte).to_digit(16));
        let second = input.next().and_then(|byte| char::from(byte).to_digit(16));
        let (Some(first), Some(second)) = (first, second) else {
            return Err(invalid());
        };
        bytes.push((first * 16 + second) as u8);
    }
    let text = String::from_utf8(bytes).map_err(|_| invalid())?;
    if text.chars().any(char::is_control) {
        return Err(invalid());
    }
    Ok(text)
}

async fn upload(
    State(workspace): State<Workspace>,
    Path((project, case)): Path<(Uuid, Uuid)>,
    headers: HeaderMap,
    content: Bytes,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    let operation_id = Uuid::parse_str(field(&headers, "x-operation-id")?)
        .map_err(|_| Rejection::invalid("The upload operation is invalid."))?;
    let name = decode(field(&headers, "x-file-name")?)?;
    let caption = if headers.contains_key("x-file-caption") {
        Some(decode(field(&headers, "x-file-caption")?)?)
    } else {
        None
    };
    let access = field(&headers, "x-file-access")?.to_owned();
    let media_type = field(&headers, "content-type")?.to_owned();
    let result = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_attach_case_file($1, $2, $3, $4, $5, $6, $7, $8, $9)",
                    &[
                        &digest,
                        &project,
                        &case,
                        &operation_id,
                        &name,
                        &media_type,
                        &content.as_ref(),
                        &caption,
                        &access,
                    ],
                )?
                .try_get(0)
        })
        .await?;
    Ok(Json(result))
}

fn disposition(filename: &str, media_type: &str) -> String {
    let extension = match media_type {
        "application/pdf" => "pdf",
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "text/plain" => "txt",
        _ => "bin",
    };
    let mut value = format!("attachment; filename=\"original.{extension}\"; filename*=UTF-8''");
    for byte in filename.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            value.push(char::from(byte));
        } else {
            let _ = write!(value, "%{byte:02X}");
        }
    }
    value
}

async fn download(
    State(workspace): State<Workspace>,
    Path((project, case, file)): Path<(Uuid, Uuid, Uuid)>,
    headers: HeaderMap,
) -> Reply<impl IntoResponse> {
    let digest = session(&headers)?;
    let (name, media_type, contents): (String, String, Vec<u8>) = workspace
        .query(move |database| {
            let result = database.query_one(
                "SELECT filename, media_type, content FROM ductdelta.web_case_file($1, $2, $3, $4)",
                &[&digest, &project, &case, &file],
            )?;
            Ok((result.try_get(0)?, result.try_get(1)?, result.try_get(2)?))
        })
        .await?;
    let disposition = disposition(&name, &media_type);
    Ok((
        [
            (header::CONTENT_TYPE, media_type),
            (header::CONTENT_DISPOSITION, disposition),
        ],
        contents,
    ))
}
