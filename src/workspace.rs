//! Same-origin workspace backed by scoped PostgreSQL commands.

use std::env;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::{DefaultBodyLimit, Path, Query, Request, State};
use axum::http::header;
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, Uri};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::{Json, Router, routing};
use postgres::{Client, Error};
use serde::Deserialize;
use serde_json::{Value, json};
use subtle::ConstantTimeEq;
use tokio::net::TcpListener;
use tokio::runtime;
use uuid::Uuid;

use crate::DatabaseTransport;
use crate::entra::Entra;
use crate::invitation_mailer::InvitationMailer;
use crate::observation;
use crate::postgres_pool::{PostgresPool, QueryError};

#[derive(Clone)]
pub(crate) struct Workspace {
    database: Arc<PostgresPool>,
    origin: String,
    host: String,
    secure: bool,
    railway: bool,
    invitation_mailer: Option<Arc<InvitationMailer>>,
    email_sign_in: bool,
    entra: Option<Entra>,
    company_setup_code: Option<Vec<u8>>,
}

pub(crate) struct Rejection(StatusCode, &'static str);
pub(crate) type Reply<T> = Result<T, Rejection>;

impl Rejection {
    pub(crate) const fn unauthorized(message: &'static str) -> Self {
        Self(StatusCode::UNAUTHORIZED, message)
    }

    pub(crate) const fn invalid(message: &'static str) -> Self {
        Self(StatusCode::UNPROCESSABLE_ENTITY, message)
    }

    pub(crate) const fn unavailable(message: &'static str) -> Self {
        Self(StatusCode::SERVICE_UNAVAILABLE, message)
    }

    pub(crate) const fn forbidden(message: &'static str) -> Self {
        Self(StatusCode::FORBIDDEN, message)
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
            Some("DD004") => Self(
                StatusCode::TOO_MANY_REQUESTS,
                "This company sent too many invitations. Try again later.",
            ),
            Some("DD005") => Self(
                StatusCode::CONFLICT,
                "The notice rule changed. Refresh the rule and review it before trying again.",
            ),
            Some("DD006") => Self(
                StatusCode::UNPROCESSABLE_ENTITY,
                "The local cutoff does not exist in this time zone. Ask an administrator to publish a manual deadline rule.",
            ),
            Some("DD008") => Self(
                StatusCode::FORBIDDEN,
                "Sign in again before generating a recovery code.",
            ),
            Some("DD007") => Self(
                StatusCode::FORBIDDEN,
                "Sign in with your company work account from Account security to use this feature.",
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
    pub(crate) fn entra(&self) -> Option<&Entra> {
        self.entra.as_ref()
    }

    pub(crate) fn email_sign_in(&self) -> bool {
        self.email_sign_in
    }

    pub(crate) fn require_legacy_sign_in(&self) -> Reply<()> {
        if self.email_sign_in {
            return Err(Rejection::forbidden(
                "Continue with an emailed sign-in code.",
            ));
        }
        Ok(())
    }

    pub(crate) fn invitation_mailer(&self) -> Option<&InvitationMailer> {
        self.invitation_mailer.as_deref()
    }

    pub(crate) fn origin(&self) -> &str {
        &self.origin
    }

    pub(crate) fn company_setup_code_required(&self) -> bool {
        self.company_setup_code.is_some()
    }

    pub(crate) fn check_company_setup_code(&self, candidate: Option<&str>) -> Reply<()> {
        let Some(expected) = &self.company_setup_code else {
            return Ok(());
        };
        let matches = candidate
            .filter(|value| valid_key(value))
            .is_some_and(|value| {
                let submitted = key_digest(value);
                bool::from(expected.ct_eq(&submitted))
            });
        if matches {
            Ok(())
        } else {
            Err(Rejection::forbidden(
                "Enter the company setup code from your deployment administrator.",
            ))
        }
    }

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
    let railway = env::var("DUCTDELTA_RAILWAY").as_deref() == Ok("1");
    let listen = listen_address(railway)?;
    let origin = env::var("DUCTDELTA_ORIGIN").unwrap_or_else(|_| format!("http://{listen}"));
    let uri: Uri = origin.parse().map_err(|_| "Invalid DUCTDELTA_ORIGIN.")?;
    let authority = uri.authority().ok_or("Invalid DUCTDELTA_ORIGIN.")?;
    let secure = uri.scheme_str() == Some("https");
    if origin != format!("{}://{authority}", uri.scheme_str().unwrap_or_default())
        || (!secure && (railway || origin != format!("http://{listen}")))
    {
        return Err("Use an HTTPS origin or the exact local listener URL.");
    }
    let trace_requests = crate::request_trace::enabled(secure)?;
    let transport = if railway {
        DatabaseTransport::RailwayPrivate
    } else {
        DatabaseTransport::LocalSocket
    };
    let mut database = crate::database_config(transport)?;
    database.connect_timeout(Duration::from_secs(3));
    database.options("-c statement_timeout=8000 -c lock_timeout=5000");
    // Keep a pool owner on this thread so the synchronous clients close outside
    // the async runtime.
    let database = Arc::new(PostgresPool::new(database, 16));
    let company_setup_code = env::var_os("DUCTDELTA_COMPANY_SETUP_CODE")
        .map(|value| {
            value
                .into_string()
                .ok()
                .filter(|value| valid_key(value))
                .map(|value| key_digest(&value))
                .ok_or("Set DUCTDELTA_COMPANY_SETUP_CODE to a random value with 64 hex digits.")
        })
        .transpose()?;
    let invitation_mailer = InvitationMailer::from_env(&origin, secure)?.map(Arc::new);
    let entra = Entra::from_env(&origin, secure)?;
    let email_sign_in = match env::var("DUCTDELTA_EMAIL_SIGN_IN").as_deref() {
        Ok("1") => true,
        Err(env::VarError::NotPresent) => secure,
        _ => return Err("Set DUCTDELTA_EMAIL_SIGN_IN to 1 or omit it."),
    };
    if email_sign_in && invitation_mailer.is_none() {
        return Err("Configure the Resend mailer before enabling email sign-in.");
    }
    if company_setup_code.is_none() {
        if railway {
            return Err("Set DUCTDELTA_COMPANY_SETUP_CODE for the Railway deployment.");
        }
        if secure {
            return Err("Set DUCTDELTA_COMPANY_SETUP_CODE before enabling company registration.");
        }
    }
    let workspace = Workspace {
        database: Arc::clone(&database),
        host: authority.as_str().to_owned(),
        origin,
        secure,
        railway,
        invitation_mailer,
        email_sign_in,
        entra,
        company_setup_code,
    };
    let runtime = runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|_| "Could not start the web runtime.")?;
    runtime.block_on(async move {
        if let Some(mailer) = workspace.invitation_mailer.clone() {
            if workspace.email_sign_in {
                let code_mailer = Arc::clone(&mailer);
                let code_workspace = workspace.clone();
                tokio::spawn(async move {
                    crate::email_sign_in::deliver_queued(&code_mailer, &code_workspace).await
                });
            }
            let activity_mailer = Arc::clone(&mailer);
            let activity_workspace = workspace.clone();
            tokio::spawn(async move {
                crate::activity_email::deliver_queued(&activity_mailer, &activity_workspace).await
            });
            let mail_workspace = workspace.clone();
            tokio::spawn(async move { mailer.deliver_queued(&mail_workspace).await });
        }
        let app = Router::new()
            .merge(crate::frontend::routes()?)
            .route("/healthz", routing::get(health))
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
            .merge(crate::account_sessions::routes())
            .merge(crate::company_setup::routes())
            .merge(crate::company_team::routes())
            .merge(crate::email_sign_in::routes())
            .merge(crate::entra::routes())
            .merge(crate::company_access_history::routes())
            .merge(crate::cases::routes())
            .merge(crate::notice_rules::routes())
            .merge(crate::evidence::routes())
            .merge(crate::issued_notice::routes())
            .merge(crate::overview::routes())
            .layer(DefaultBodyLimit::max(64 * 1024))
            .layer(middleware::from_fn_with_state(
                workspace.clone(),
                same_origin,
            ))
            .layer(middleware::from_fn(move |request, next| {
                crate::request_trace::record(trace_requests, request, next)
            }))
            .with_state(workspace);
        let listener = TcpListener::bind(listen)
            .await
            .map_err(|_| "Could not bind the workspace.")?;
        axum::serve(listener, app)
            .await
            .map_err(|_| "Workspace stopped unexpectedly.")
    })
}

fn listen_address(railway: bool) -> Result<SocketAddr, &'static str> {
    if railway {
        let port = env::var("PORT")
            .ok()
            .and_then(|value| value.parse::<u16>().ok())
            .filter(|port| *port != 0)
            .ok_or("Set PORT to the Railway service port.")?;
        return Ok(SocketAddr::from(([0, 0, 0, 0], port)));
    }
    let listen: SocketAddr = env::var("DUCTDELTA_LISTEN")
        .unwrap_or_else(|_| "127.0.0.1:3000".to_owned())
        .parse()
        .map_err(|_| "Use a loopback address for DUCTDELTA_LISTEN.")?;
    if !listen.ip().is_loopback() {
        return Err("Bind DuctDelta on loopback and use a TLS proxy for remote access.");
    }
    Ok(listen)
}

async fn health(State(workspace): State<Workspace>) -> StatusCode {
    let entra_available = workspace.entra().is_some();
    let ready = workspace
        .query(move |client| {
            client
                .query_one(
                    "SELECT NOT (rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls)
                        AND pg_has_role('ductdelta_web_runtime', 'USAGE')
                        AND NOT pg_has_role('ductdelta_owner', 'MEMBER')
                        AND has_function_privilege(
                            'ductdelta.web_account_sessions(bytea)', 'EXECUTE')
                        AND has_function_privilege('ductdelta.claim_activity_email()', 'EXECUTE')
                        AND has_function_privilege(
                            'ductdelta.finish_activity_email(uuid,integer,uuid,integer)', 'EXECUTE')
                        AND has_function_privilege('ductdelta.claim_email_code()', 'EXECUTE')
                        AND has_function_privilege(
                            'ductdelta.web_verify_email_code(uuid,bytea,bytea)', 'EXECUTE')
                        AND has_function_privilege(
                            'ductdelta.web_entra_login(uuid,uuid,uuid,text,bytea,integer)', 'EXECUTE')
                        AND ($1 OR NOT ductdelta.web_entra_configured())
                     FROM pg_catalog.pg_roles WHERE rolname = current_user",
                    &[&entra_available],
                )
                .map(|row| row.get::<_, bool>(0))
        })
        .await;
    if matches!(ready, Ok(true)) {
        StatusCode::NO_CONTENT
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    }
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
    let railway_health = workspace.railway
        && host == Some("healthcheck.railway.app")
        && request.method() == Method::GET
        && request.uri().path() == "/healthz";
    let mut response = if (host != Some(workspace.host.as_str()) && !railway_health)
        || (!request.method().is_safe() && origin != Some(workspace.origin.as_str()))
    {
        Rejection(StatusCode::FORBIDDEN, "Request origin is not allowed.").into_response()
    } else {
        next.run(request).await
    };
    let headers = response.headers_mut();
    if workspace.secure {
        headers.insert(
            header::STRICT_TRANSPORT_SECURITY,
            HeaderValue::from_static("max-age=31536000"),
        );
    }
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
    cookie_token(headers, "dd_session")
        .map(key_digest)
        .ok_or_else(|| Rejection::unauthorized("Sign in required."))
}

pub(crate) fn cookie_token<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(';'))
        .filter_map(|pair| pair.trim().split_once('='))
        .find_map(|(key, token)| (key == name && valid_key(token)).then_some(token))
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
    workspace.require_legacy_sign_in()?;
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
    let changed = database.execute(
        "INSERT INTO ductdelta.web_access_key (actor_id, display_name, key_digest, expires_at)
         VALUES ($1, $2, $3, statement_timestamp() + interval '30 days')
         ON CONFLICT (actor_id) DO UPDATE SET
             display_name = excluded.display_name, key_digest = excluded.key_digest, expires_at = excluded.expires_at
         WHERE ductdelta.web_access_key.email IS NULL",
        &[&actor, &name, &key_digest(&key)],
    ).map_err(|_| "Could not issue the key. Use a migration administrator and an existing actor.")?;
    if changed == 0 {
        return Err("This account uses email sign-in.");
    }
    Ok(key)
}
