//! Serve the prebuilt workspace, public product page, and browser assets.

use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::{Path as FilePath, PathBuf};
use std::sync::Arc;

use axum::Router;
use axum::body::Bytes;
use axum::extract::{OriginalUri, Path, State};
use axum::http::header;
use axum::http::header::HeaderValue;
use axum::http::{StatusCode, Uri};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing;

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
    fn load(directory: &FilePath) -> Result<Self, &'static str> {
        let shell = read_file(&directory.join("workspace/index.html")).map_err(
            |_| "Build the Nuxt workspace and set DUCTDELTA_WEB_DIST to .output/public.",
        )?;
        // Nuxt UI uses inline attributes for component sizing and transitions.
        let policy = content_policy(
            directory,
            "; form-action 'self'; style-src-attr 'unsafe-inline'",
        )?;
        let nuxt_assets = directory.join("_nuxt");
        if !fs::symlink_metadata(&nuxt_assets).is_ok_and(|metadata| metadata.is_dir()) {
            return Err("Nuxt assets are missing. Rebuild the Nuxt workspace.");
        }
        let mut assets = HashMap::new();
        load_assets(&nuxt_assets, "", &mut assets)?;
        if assets.is_empty() {
            return Err("The Nuxt workspace has no compiled assets.");
        }

        Ok(Self {
            shell: shell.into(),
            policy,
            assets,
        })
    }
}

fn read_file(path: &FilePath) -> Result<Vec<u8>, std::io::Error> {
    if !fs::symlink_metadata(path)?.is_file() {
        return Err(std::io::ErrorKind::InvalidData.into());
    }
    fs::read(path)
}

fn read_hashes(path: &FilePath) -> Result<String, &'static str> {
    read_file(path)
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .ok_or("Frontend content hashes are missing or invalid. Rebuild the Nuxt workspace.")
}

fn content_policy(directory: &FilePath, constraints: &str) -> Result<HeaderValue, &'static str> {
    let scripts = read_hashes(&directory.join("script-hashes.txt"))?;
    let styles = read_hashes(&directory.join("style-hashes.txt"))?;
    let mut policy = String::from(concat!(
        "default-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; ",
        "script-src 'self'",
    ));
    append_hashes(&mut policy, &scripts)?;
    policy.push_str("; style-src 'self'");
    append_hashes(&mut policy, &styles)?;
    policy.push_str(constraints);
    HeaderValue::from_str(&policy).map_err(|_| "Invalid frontend content policy.")
}

fn append_hashes(policy: &mut String, hashes: &str) -> Result<(), &'static str> {
    if hashes.is_empty() {
        return Err("Frontend content hashes are missing. Rebuild the Nuxt workspace.");
    }
    for hash in hashes.lines() {
        let bytes = hash.as_bytes();
        if bytes.len() != 44
            || bytes[43] != b'='
            || !bytes[..43]
                .iter()
                .all(|&byte| byte.is_ascii_alphanumeric() || byte == b'+' || byte == b'/')
        {
            return Err("Frontend content hash is invalid.");
        }
        policy.push_str(" 'sha256-");
        policy.push_str(hash);
        policy.push('\'');
    }
    Ok(())
}

fn load_assets(
    directory: &FilePath,
    prefix: &str,
    assets: &mut HashMap<String, Asset>,
) -> Result<(), &'static str> {
    let entries = fs::read_dir(directory).map_err(|_| "Could not open the frontend assets.")?;
    for entry in entries {
        let entry = entry.map_err(|_| "Could not read a frontend asset.")?;
        let file_type = entry
            .file_type()
            .map_err(|_| "Could not read a frontend asset.")?;
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if name.starts_with('.')
            || !name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            continue;
        }
        if file_type.is_dir() {
            load_assets(&entry.path(), &format!("{prefix}{name}/"), assets)?;
        } else if file_type.is_file()
            && let Some(media_type) = media_type(&name)
        {
            let bytes = read_file(&entry.path()).map_err(|_| "Could not read a frontend asset.")?;
            assets.insert(
                format!("{prefix}{name}"),
                Asset {
                    media_type,
                    bytes: bytes.into(),
                },
            );
        }
    }
    Ok(())
}

fn media_type(name: &str) -> Option<&'static str> {
    match name.rsplit_once('.')?.1 {
        "js" | "mjs" => Some("text/javascript; charset=utf-8"),
        "css" => Some("text/css; charset=utf-8"),
        "woff" => Some("font/woff"),
        "woff2" => Some("font/woff2"),
        "ttf" => Some("font/ttf"),
        "otf" => Some("font/otf"),
        "avif" => Some("image/avif"),
        "webp" => Some("image/webp"),
        "png" => Some("image/png"),
        "txt" => Some("text/plain; charset=utf-8"),
        "xml" => Some("application/xml; charset=utf-8"),
        _ => None,
    }
}

fn cached_asset(asset: &Asset) -> Response {
    (
        [
            (header::CONTENT_TYPE, asset.media_type),
            (header::CACHE_CONTROL, "public, max-age=31536000, immutable"),
        ],
        asset.bytes.clone(),
    )
        .into_response()
}

#[derive(Clone)]
struct PublicPage {
    html: Bytes,
    policy: HeaderValue,
}

impl PublicPage {
    fn load(directory: &FilePath, file: &str) -> Result<Self, &'static str> {
        let html = read_file(&directory.join(file)).map_err(|_| "A marketing page is missing.")?;
        let policy = read_hashes(&directory.join(format!("{file}.csp")))?;
        let policy = HeaderValue::from_str(policy.trim_end())
            .map_err(|_| "A marketing page has an invalid content policy.")?;
        Ok(Self {
            html: html.into(),
            policy,
        })
    }

    fn response(&self, indexable: bool) -> Response {
        let mut response = (
            [
                (header::CONTENT_SECURITY_POLICY, self.policy.clone()),
                (
                    header::REFERRER_POLICY,
                    HeaderValue::from_static("strict-origin-when-cross-origin"),
                ),
            ],
            Html(self.html.clone()),
        )
            .into_response();
        if !indexable {
            response
                .headers_mut()
                .insert("x-robots-tag", HeaderValue::from_static("noindex, follow"));
        }
        response
    }
}

fn with_query(path: &str, uri: &Uri) -> String {
    match uri.query() {
        Some(query) => format!("{path}?{query}"),
        None => path.to_owned(),
    }
}

fn old_workspace_link(uri: &Uri) -> bool {
    uri.query().is_some_and(|query| {
        query.split('&').any(|part| {
            let name = part.split_once('=').map_or(part, |(name, _)| name);
            matches!(
                name,
                "project" | "view" | "caseId" | "observationId" | "recover" | "sso" | "sso_error"
            )
        })
    })
}

fn marketing_routes(
    directory: &FilePath,
    legacy_product: &FilePath,
) -> Result<Router<Workspace>, &'static str> {
    let home = PublicPage::load(directory, "index.html")?;
    let missing = PublicPage::load(directory, "404.html")?;
    let mut assets = HashMap::new();
    load_assets(directory, "", &mut assets)?;
    let assets = Arc::new(assets);
    let root_files = Arc::clone(&assets);
    let scripts = Arc::clone(&assets);
    let mut legacy = HashMap::new();
    load_assets(&legacy_product.join("_astro"), "", &mut legacy)?;
    let legacy = Arc::new(legacy);

    let home_alias = routing::get(|OriginalUri(uri): OriginalUri| async move {
        Redirect::permanent(&with_query("/", &uri))
    });
    let mut router = Router::new()
        .route(
            "/",
            routing::get(move |State(workspace): State<Workspace>, OriginalUri(uri): OriginalUri| async move {
                if old_workspace_link(&uri) {
                    return (
                        StatusCode::FOUND,
                        [(header::LOCATION, with_query("/workspace/", &uri))],
                    )
                        .into_response();
                }
                home.response(workspace.origin() == "https://ductdelta.com")
            }),
        )
        .route("/product", home_alias.clone())
        .route("/product/", home_alias)
        .route(
            "/product/healthz",
            routing::get(|| async { StatusCode::NO_CONTENT }),
        )
        .route(
            "/product/sitemap.xml",
            routing::get(|OriginalUri(uri): OriginalUri| async move {
                Redirect::permanent(&with_query("/sitemap.xml", &uri))
            }),
        )
        // Pages from the previous release can still have these cached asset URLs.
        .route(
            "/product/_astro/{*path}",
            routing::get(move |Path(path): Path<String>| async move {
                legacy
                    .get(&path)
                    .map_or_else(|| StatusCode::NOT_FOUND.into_response(), cached_asset)
            }),
        )
        .route(
            "/_next/static/{*path}",
            routing::get(move |Path(path): Path<String>| async move {
                scripts
                    .get(&format!("_next/static/{path}"))
                    .map_or_else(|| StatusCode::NOT_FOUND.into_response(), cached_asset)
            }),
        )
        .route(
            "/{file}",
            routing::get(move |Path(file): Path<String>| async move {
                public_asset(root_files.get(&file))
            }),
        )
        .route(
            "/product/{*path}",
            routing::get(move |Path(path): Path<String>| async move {
                match assets.get(&format!("product/{path}")) {
                    Some(asset) => public_asset(Some(asset)),
                    None if path.starts_with("media/") => StatusCode::NOT_FOUND.into_response(),
                    None => (StatusCode::NOT_FOUND, missing.response(false)).into_response(),
                }
            }),
        );

    for (path, file) in [
        ("/product/workflow", "product/workflow/index.html"),
        ("/product/example", "product/example/index.html"),
        ("/product/faq", "product/faq/index.html"),
    ] {
        let page = PublicPage::load(directory, file)?;
        let canonical = format!("{path}/");
        router = router
            .route(
                path,
                routing::get({
                    let canonical = canonical.clone();
                    move |OriginalUri(uri): OriginalUri| async move {
                        Redirect::permanent(&with_query(&canonical, &uri))
                    }
                }),
            )
            .route(
                &canonical,
                routing::get(move |State(workspace): State<Workspace>| async move {
                    page.response(workspace.origin() == "https://ductdelta.com")
                }),
            );
    }
    Ok(router)
}

fn public_asset(asset: Option<&Asset>) -> Response {
    match asset {
        Some(asset) => (
            [(header::CONTENT_TYPE, asset.media_type)],
            asset.bytes.clone(),
        )
            .into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

pub(crate) fn routes() -> Result<Router<Workspace>, &'static str> {
    let Some(directory) = env::var_os("DUCTDELTA_WEB_DIST") else {
        return Ok(Router::new().route(
            "/",
            routing::get(|| async {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Workspace assets are unavailable.",
                )
            }),
        ));
    };

    let directory = PathBuf::from(directory);
    let marketing = marketing_routes(&directory.join("marketing"), &directory.join("product"))?;
    let frontend = Arc::new(Frontend::load(&directory)?);
    let page = Arc::clone(&frontend);
    Ok(Router::new()
        .route(
            "/workspace",
            routing::get(|OriginalUri(uri): OriginalUri| async move {
                Redirect::permanent(&with_query("/workspace/", &uri))
            }),
        )
        .route(
            "/workspace/",
            routing::get(move || async move {
                (
                    [(header::CONTENT_SECURITY_POLICY, page.policy.clone())],
                    Html(page.shell.clone()),
                )
            }),
        )
        .merge(marketing)
        .route(
            "/_nuxt/{*path}",
            routing::get(move |Path(path): Path<String>| async move {
                match frontend.assets.get(&path) {
                    Some(asset) => {
                        let mut response = cached_asset(asset);
                        if asset.media_type == "font/woff2" && path.starts_with("fonts/") {
                            response.headers_mut().insert(
                                header::ACCESS_CONTROL_ALLOW_ORIGIN,
                                HeaderValue::from_static("*"),
                            );
                        }
                        response
                    }
                    None => StatusCode::NOT_FOUND.into_response(),
                }
            }),
        ))
}
