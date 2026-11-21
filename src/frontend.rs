//! Serve the compiled TanStack Start shell and its versioned assets.

use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

use axum::Router;
use axum::body::Bytes;
use axum::extract::Path;
use axum::http::StatusCode;
use axum::http::header::{self, HeaderValue};
use axum::response::{Html, IntoResponse};
use axum::routing::get;

use crate::workspace::Workspace;

struct Asset {
    media_type: &'static str,
    bytes: Bytes,
}

struct Frontend {
    shell: Bytes,
    policy: HeaderValue,
    assets: HashMap<String, Asset>,
}

impl Frontend {
    fn load(directory: PathBuf) -> Result<Self, &'static str> {
        let shell = fs::read(directory.join("_shell.html")).map_err(
            |_| "Build the TanStack workspace and set DUCTDELTA_WEB_DIST to dist/client.",
        )?;
        let hashes = fs::read_to_string(directory.join("script-hashes.txt"))
            .map_err(|_| "Frontend script hashes are missing. Rebuild the TanStack workspace.")?;
        let mut policy = String::from(
            "default-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self'",
        );
        for hash in hashes.lines().filter(|line| !line.is_empty()) {
            if hash.len() != 44
                || !hash.ends_with('=')
                || !hash[..43]
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'+' || byte == b'/')
            {
                return Err("Frontend script hash is invalid.");
            }
            policy.push_str(" 'sha256-");
            policy.push_str(hash);
            policy.push('\'');
        }
        let policy =
            HeaderValue::from_str(&policy).map_err(|_| "Invalid frontend content policy.")?;
        let directory = fs::read_dir(directory.join("assets"))
            .map_err(|_| "Frontend assets are missing. Rebuild the TanStack workspace.")?;
        let mut assets = HashMap::new();
        for entry in directory {
            let entry = entry.map_err(|_| "Could not read a frontend asset.")?;
            let file_type = entry
                .file_type()
                .map_err(|_| "Could not read a frontend asset.")?;
            if !file_type.is_file() {
                continue;
            }
            let Ok(name) = entry.file_name().into_string() else {
                continue;
            };
            let media_type = if name.ends_with(".js") {
                "text/javascript; charset=utf-8"
            } else if name.ends_with(".css") {
                "text/css; charset=utf-8"
            } else {
                continue;
            };
            let bytes = fs::read(entry.path()).map_err(|_| "Could not read a frontend asset.")?;
            assets.insert(
                name,
                Asset {
                    media_type,
                    bytes: bytes.into(),
                },
            );
        }
        if assets.is_empty() {
            return Err("The TanStack workspace has no compiled assets.");
        }
        Ok(Self {
            shell: shell.into(),
            policy,
            assets,
        })
    }
}

pub(crate) fn routes() -> Result<Router<Workspace>, &'static str> {
    let Some(directory) = env::var_os("DUCTDELTA_WEB_DIST") else {
        return Ok(Router::new().route(
            "/",
            get(|| async {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Workspace assets are unavailable.",
                )
            }),
        ));
    };
    let frontend = Arc::new(Frontend::load(directory.into())?);
    let page = Arc::clone(&frontend);
    Ok(Router::new()
        .route(
            "/",
            get(move || async move {
                (
                    [(header::CONTENT_SECURITY_POLICY, page.policy.clone())],
                    Html(page.shell.clone()),
                )
            }),
        )
        .route(
            "/assets/{name}",
            get(move |Path(name): Path<String>| async move {
                match frontend.assets.get(&name) {
                    Some(asset) => (
                        [
                            (header::CONTENT_TYPE, asset.media_type),
                            (header::CACHE_CONTROL, "public, max-age=31536000, immutable"),
                        ],
                        asset.bytes.clone(),
                    )
                        .into_response(),
                    None => StatusCode::NOT_FOUND.into_response(),
                }
            }),
        ))
}
