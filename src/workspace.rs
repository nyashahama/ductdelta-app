//! Same-origin workspace backed by scoped PostgreSQL commands.

use std::env;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::{DefaultBodyLimit, Path, Query, Request, State};
use axum::http::header;
use axum::http::{HeaderMap, HeaderValue, StatusCode, Uri};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::{Json, Router, routing};
use postgres::{Client, Error};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::runtime;
use uuid::Uuid;

use crate::observation;
use crate::postgres_pool::{PostgresPool, QueryError};

#[derive(Clone)]
pub(crate) struct Workspace {
    database: Arc<PostgresPool>,
    origin: String,
    host: String,
    secure: bool,
}

pub(crate) struct Rejection(StatusCode, &'static str);
pub(crate) type Reply<T> = Result<T, Rejection>;

impl Rejection {
    pub(crate) const fn invalid(message: &'static str) -> Self {
        Self(StatusCode::UNPROCESSABLE_ENTITY, message)
    }
}

impl IntoResponse for Rejection {
    fn into_response(self) -> Response {
        (self.0, Json(json!({"message": self.1}))).into_response()
    }
}

impl From<Error> for Rejection {
    fn from(error: Error) -> Self {
        match error.code().map(|value| value.code()) {
            Some("28000") => Self(StatusCode::UNAUTHORIZED, "Sign in required."),
            Some("42501") => Self(StatusCode::NOT_FOUND, "This record is unavailable."),
            Some("DD003") => Self(
                StatusCode::UNPROCESSABLE_ENTITY,
                "Resolve every open or disputed quote line before closing the case.",
            ),
            Some("DD002") => Self(
                StatusCode::CONFLICT,
                "Keep at least one company administrator.",
            ),
            Some("DD001" | "40001" | "23505") => Self(
                StatusCode::CONFLICT,
                "The operation conflicts with a saved record.",
            ),
            Some("22023" | "22007" | "22008" | "22009" | "22P02" | "23503" | "23514" | "23502") => {
                Self(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "Check the submitted details.",
                )
            }
            _ => Self(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Could not complete the operation.",
            ),
        }
    }
}

impl Workspace {
    pub(crate) async fn query<T: Send + 'static>(
        &self,
        action: impl FnOnce(&mut Client) -> Result<T, Error> + Send + 'static,
    ) -> Reply<T> {
        self.database
            .run(action)
            .await
            .map_err(|error| match error {
                QueryError::Busy => Rejection(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Workspace busy. Try again.",
                ),
                QueryError::WorkerFailed => Rejection(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Could not complete the operation.",
                ),
                QueryError::Database(error) => Rejection::from(error),
            })
    }
}

pub(crate) fn serve() -> Result<(), &'static str> {
    let listen: SocketAddr = env::var("DUCTDELTA_LISTEN")
        .unwrap_or_else(|_| "127.0.0.1:3000".to_owned())
        .parse()
        .map_err(|_| "Use a loopback address for DUCTDELTA_LISTEN.")?;
    if !listen.ip().is_loopback() {
        return Err("Bind DuctDelta on loopback and use a TLS proxy for remote access.");
    }
    let origin = env::var("DUCTDELTA_ORIGIN").unwrap_or_else(|_| format!("http://{listen}"));
    let uri: Uri = origin.parse().map_err(|_| "Invalid DUCTDELTA_ORIGIN.")?;
    let authority = uri.authority().ok_or("Invalid DUCTDELTA_ORIGIN.")?;
    let secure = uri.scheme_str() == Some("https");
    if origin != format!("{}://{authority}", uri.scheme_str().unwrap_or_default())
        || (!secure && origin != format!("http://{listen}"))
    {
        return Err("Use an HTTPS origin or the exact local listener URL.");
    }
    let mut database = crate::database_config()?;
    database.connect_timeout(Duration::from_secs(3));
    database.options("-c statement_timeout=8000 -c lock_timeout=5000");
    // Keep a pool owner on this thread so the synchronous clients close outside
    // the async runtime.
    let database = Arc::new(PostgresPool::new(database, 16));
    let workspace = Workspace {
        database: Arc::clone(&database),
        host: authority.as_str().to_owned(),
        origin,
        secure,
    };
    let runtime = runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|_| "Could not start the web runtime.")?;
    runtime.block_on(async move {
        let app = Router::new()
            .merge(crate::frontend::routes()?)
            .route(
                "/healthz",
                routing::get(|| async { StatusCode::NO_CONTENT }),
            )
            .route(
                "/api/session",
                routing::get(session_info).post(sign_in).delete(sign_out),
            )
            .route("/api/projects", routing::get(projects))
            .route(
                "/api/projects/{project}/observations",
                routing::get(observations).post(capture),
            )
            .route(
                "/api/projects/{project}/observations/{observation}",
                routing::get(observation_detail),
            )
            .merge(crate::company_setup::routes())
            .merge(crate::company_team::routes())
            .merge(crate::company_access_history::routes())
            .merge(crate::cases::routes())
            .merge(crate::evidence::routes())
            .merge(crate::overview::routes())
            .layer(DefaultBodyLimit::max(64 * 1024))
            .layer(middleware::from_fn_with_state(
                workspace.clone(),
                same_origin,
            ))
            .with_state(workspace);
        let listener = TcpListener::bind(listen)
            .await
            .map_err(|_| "Could not bind the workspace.")?;
        axum::serve(listener, app)
            .await
            .map_err(|_| "Workspace stopped unexpectedly.")
    })
}

async fn same_origin(State(workspace): State<Workspace>, request: Request, next: Next) -> Response {
    let host = request
        .headers()
        .get(header::HOST)
        .and_then(|value| value.to_str().ok());
    let origin = request
        .headers()
        .get(header::ORIGIN)
        .and_then(|value| value.to_str().ok());
    if host != Some(workspace.host.as_str())
        || (!request.method().is_safe() && origin != Some(workspace.origin.as_str()))
    {
        return Rejection(StatusCode::FORBIDDEN, "Request origin is not allowed.").into_response();
    }
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers
        .entry(header::CACHE_CONTROL)
        .or_insert(HeaderValue::from_static("no-store"));
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.entry(header::CONTENT_SECURITY_POLICY).or_insert(HeaderValue::from_static(
        "default-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
    ));
    response
}

pub(crate) fn random_key() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

pub(crate) fn key_digest(key: &str) -> Vec<u8> {
    use sha2::Digest;
    sha2::Sha256::digest(key.as_bytes()).to_vec()
}

pub(crate) fn valid_key(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

pub(crate) fn session(headers: &HeaderMap) -> Reply<Vec<u8>> {
    for value in headers.get_all(header::COOKIE).iter() {
        if let Ok(value) = value.to_str() {
            for pair in value.split(';') {
                if let Some(token) = pair.trim().strip_prefix("dd_session=")
                    && valid_key(token)
                {
                    return Ok(key_digest(token));
                }
            }
        }
    }
    Err(Rejection(StatusCode::UNAUTHORIZED, "Sign in required."))
}

pub(crate) fn session_cookie(workspace: &Workspace, token: &str, age: u32) -> HeaderValue {
    let secure = if workspace.secure { "; Secure" } else { "" };
    let cookie =
        format!("dd_session={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={age}{secure}");
    HeaderValue::from_str(&cookie).expect("session cookie contains fixed attributes and hex tokens")
}

#[derive(Deserialize)]
struct Login {
    key: String,
}

async fn sign_in(State(workspace): State<Workspace>, Json(input): Json<Login>) -> Reply<Response> {
    if !valid_key(&input.key) {
        return Err(Rejection(
            StatusCode::UNAUTHORIZED,
            "The access key is invalid.",
        ));
    }
    let token = random_key();
    let credentials = key_digest(&input.key);
    let digest = key_digest(&token);
    let accepted: bool = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_login($1, $2)",
                    &[&credentials, &digest],
                )?
                .try_get(0)
        })
        .await?;
    if !accepted {
        return Err(Rejection(
            StatusCode::UNAUTHORIZED,
            "The access key is invalid.",
        ));
    }
    Ok((
        StatusCode::NO_CONTENT,
        [(
            header::SET_COOKIE,
            session_cookie(&workspace, &token, 43_200),
        )],
    )
        .into_response())
}

async fn sign_out(State(workspace): State<Workspace>, headers: HeaderMap) -> Reply<Response> {
    if let Ok(digest) = session(&headers) {
        workspace
            .query(move |database| database.execute("SELECT ductdelta.web_logout($1)", &[&digest]))
            .await?;
    }
    Ok((
        StatusCode::NO_CONTENT,
        [(header::SET_COOKIE, session_cookie(&workspace, "", 0))],
    )
        .into_response())
}

async fn session_info(
    State(workspace): State<Workspace>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    Ok(Json(
        workspace
            .query(move |database| {
                database
                    .query_one("SELECT ductdelta.web_self($1)", &[&digest])?
                    .try_get(0)
            })
            .await?,
    ))
}

async fn projects(State(workspace): State<Workspace>, headers: HeaderMap) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    Ok(Json(
        workspace
            .query(move |database| {
                database
                    .query_one("SELECT ductdelta.web_projects($1)", &[&digest])?
                    .try_get(0)
            })
            .await?,
    ))
}

#[derive(Deserialize)]
struct Page {
    before: Option<Uuid>,
}

async fn observations(
    State(workspace): State<Workspace>,
    Path(project): Path<Uuid>,
    headers: HeaderMap,
    Query(page): Query<Page>,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    Ok(Json(
        workspace
            .query(move |database| {
                database
                    .query_one(
                        "SELECT ductdelta.web_observations($1, $2, $3)",
                        &[&digest, &project, &page.before],
                    )?
                    .try_get(0)
            })
            .await?,
    ))
}

async fn observation_detail(
    State(workspace): State<Workspace>,
    Path((project, id)): Path<(Uuid, Uuid)>,
    headers: HeaderMap,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    Ok(Json(
        workspace
            .query(move |database| {
                database
                    .query_one(
                        "SELECT ductdelta.web_observation($1, $2, $3)",
                        &[&digest, &project, &id],
                    )?
                    .try_get(0)
            })
            .await?,
    ))
}

#[derive(Deserialize)]
struct Capture {
    operation_id: Uuid,
    observed_at: Option<String>,
    location: Option<String>,
    note: String,
}

async fn capture(
    State(workspace): State<Workspace>,
    Path(project): Path<Uuid>,
    headers: HeaderMap,
    Json(input): Json<Capture>,
) -> Reply<Json<Value>> {
    let digest = session(&headers)?;
    if !observation::valid_text(&input.note, 4000)
        || input
            .location
            .as_ref()
            .is_some_and(|value| !observation::valid_text(value, 120))
    {
        return Err(Rejection(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Enter a note and a valid optional location.",
        ));
    }
    let observed_at = input
        .observed_at
        .as_deref()
        .map(observation::parse_observed_time)
        .transpose()
        .map_err(|message| Rejection(StatusCode::UNPROCESSABLE_ENTITY, message))?;
    Ok(Json(
        workspace
            .query(move |database| {
                database
                    .query_one(
                        "SELECT ductdelta.web_capture($1, $2, $3, $4, $5, $6)",
                        &[
                            &digest,
                            &project,
                            &input.operation_id,
                            &observed_at,
                            &input.location,
                            &input.note,
                        ],
                    )?
                    .try_get(0)
            })
            .await?,
    ))
}

pub(crate) fn issue_key(
    database: &mut Client,
    actor: Uuid,
    name: &str,
) -> Result<String, &'static str> {
    if !observation::valid_text(name, 120) {
        return Err("Use a nonblank display name of at most 120 characters.");
    }
    let key = random_key();
    database.execute(
        "INSERT INTO ductdelta.web_access_key (actor_id, display_name, key_digest, expires_at)
         VALUES ($1, $2, $3, statement_timestamp() + interval '30 days')
         ON CONFLICT (actor_id) DO UPDATE SET
             display_name = excluded.display_name, key_digest = excluded.key_digest, expires_at = excluded.expires_at",
        &[&actor, &name, &key_digest(&key)],
    ).map_err(|_| "Could not issue the key. Use a migration administrator and an existing actor.")?;
    Ok(key)
}
