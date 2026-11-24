//! Tenant-scoped Microsoft Entra sign-in and Conditional Access.

use std::env;
use std::net::SocketAddr;
use std::time::Duration;

use axum::extract::{Query, State};
use axum::http::{HeaderMap, HeaderValue, header};
use axum::response::{IntoResponse, Redirect, Response};
use axum::{Json, Router, routing};
use openidconnect::core::{
    CoreAuthenticationFlow, CoreClient, CoreGenderClaim, CoreJsonWebKeySet,
    CoreJweContentEncryptionAlgorithm, CoreJwsSigningAlgorithm,
};
use openidconnect::{
    AdditionalClaims, AuthType, AuthUrl, AuthorizationCode, ClientId, ClientSecret, CsrfToken,
    EndpointNotSet, EndpointSet, IdToken, IssuerUrl, JsonWebKeySetUrl, Nonce, PkceCodeChallenge,
    PkceCodeVerifier, RedirectUrl, Scope, TokenResponse, TokenUrl,
};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::workspace::{self, Rejection, Reply, Workspace};

const CALLBACK: &str = "/api/account/sso/callback";
const BROWSER_COOKIE: &str = "dd_entra_browser";
const AUTHORITY: &str = "https://login.microsoftonline.com";
type WebClient =
    CoreClient<EndpointSet, EndpointNotSet, EndpointNotSet, EndpointNotSet, EndpointSet>;
type EntraToken = IdToken<
    EntraClaims,
    CoreGenderClaim,
    CoreJweContentEncryptionAlgorithm,
    CoreJwsSigningAlgorithm,
>;

#[derive(Clone)]
pub(crate) struct Entra {
    id: ClientId,
    secret: ClientSecret,
    authority: String,
    redirect: RedirectUrl,
    http: openidconnect::reqwest::Client,
}

impl Entra {
    pub(crate) fn from_env(origin: &str, secure: bool) -> Result<Option<Self>, &'static str> {
        let id = env::var_os("DUCTDELTA_ENTRA_CLIENT_ID");
        let secret = env::var_os("DUCTDELTA_ENTRA_CLIENT_SECRET");
        let authority = env::var_os("DUCTDELTA_ENTRA_TEST_AUTHORITY");
        if id.is_none() && secret.is_none() && authority.is_none() {
            return Ok(None);
        }
        let client_id = id
            .and_then(|value| value.into_string().ok())
            .and_then(|value| Uuid::parse_str(&value).ok())
            .filter(|value| !value.is_nil())
            .ok_or("Set DUCTDELTA_ENTRA_CLIENT_ID to the app registration UUID.")?;
        let secret = secret
            .and_then(|value| value.into_string().ok())
            .filter(|value| !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_graphic()))
            .ok_or("Set DUCTDELTA_ENTRA_CLIENT_SECRET to the app registration secret.")?;
        let authority = match authority {
            None => AUTHORITY.into(),
            Some(value) if !secure => value
                .into_string()
                .ok()
                .filter(|value| {
                    value
                        .strip_prefix("http://")
                        .and_then(|value| value.parse::<SocketAddr>().ok())
                        .is_some_and(|value| value.ip().is_loopback())
                })
                .ok_or("Use a numeric loopback Entra test origin.")?,
            Some(_) => return Err("The Entra test origin is only available on loopback."),
        };
        let redirect = RedirectUrl::new(format!("{origin}{CALLBACK}"))
            .map_err(|_| "Invalid Entra redirect URL.")?;
        let http = openidconnect::reqwest::Client::builder()
            .redirect(openidconnect::reqwest::redirect::Policy::none())
            .no_proxy()
            .timeout(Duration::from_secs(8))
            .build()
            .map_err(|_| "Could not start the Entra client.")?;
        Ok(Some(Self {
            id: ClientId::new(client_id.to_string()),
            secret: ClientSecret::new(secret),
            authority,
            redirect,
            http,
        }))
    }

    fn tenant_origin(&self, tenant: Uuid) -> String {
        format!("{}/{tenant}", self.authority)
    }

    fn client(&self, tenant: Uuid, keys: CoreJsonWebKeySet) -> WebClient {
        let tenant = self.tenant_origin(tenant);
        CoreClient::new(
            self.id.clone(),
            IssuerUrl::new(format!("{tenant}/v2.0")).expect("valid issuer"),
            keys,
        )
        .set_auth_uri(
            AuthUrl::new(format!("{tenant}/oauth2/v2.0/authorize"))
                .expect("valid authorization URL"),
        )
        .set_token_uri(
            TokenUrl::new(format!("{tenant}/oauth2/v2.0/token")).expect("valid token URL"),
        )
        .set_client_secret(self.secret.clone())
        .set_auth_type(AuthType::RequestBody)
        .set_redirect_uri(self.redirect.clone())
    }
}

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/account/sso/companies", routing::get(companies))
        .route("/api/account/sso/start", routing::post(start))
        .route(CALLBACK, routing::get(callback))
}

async fn companies(State(workspace): State<Workspace>, headers: HeaderMap) -> Reply<Json<Value>> {
    let session = workspace::session(&headers)?;
    if workspace.entra().is_none() {
        return Ok(Json(json!([])));
    }
    let value = workspace
        .query(move |database| {
            database
                .query_one("SELECT ductdelta.web_entra_companies($1)", &[&session])?
                .try_get(0)
        })
        .await?;
    Ok(Json(value))
}

#[derive(Deserialize)]
struct CompanySignIn {
    company: Uuid,
}

async fn start(
    State(workspace): State<Workspace>,
    Json(input): Json<CompanySignIn>,
) -> Reply<Response> {
    let entra = workspace
        .entra()
        .ok_or_else(|| Rejection::unavailable("Company sign-in is unavailable."))?;
    let nonce = Nonce::new(workspace::random_key());
    let state = CsrfToken::new(workspace::random_key());
    let browser = workspace::random_key();
    let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
    let state_digest = workspace::key_digest(state.secret());
    let browser_digest = workspace::key_digest(&browser);
    let saved_nonce = nonce.secret().clone();
    let saved_verifier = verifier.secret().clone();
    let settings = workspace
        .query(move |database| {
            database
                .query_opt(
                    "SELECT * FROM ductdelta.web_start_entra($1,$2,$3,$4,$5)",
                    &[
                        &input.company,
                        &state_digest,
                        &browser_digest,
                        &saved_nonce,
                        &saved_verifier,
                    ],
                )?
                .map(|row| {
                    Ok((
                        row.try_get::<_, Uuid>(0)?,
                        row.try_get::<_, Option<String>>(1)?,
                    ))
                })
                .transpose()
        })
        .await?;
    let (tenant, context) = settings
        .ok_or_else(|| Rejection::unavailable("Company sign-in is unavailable for this link."))?;
    let client = entra.client(tenant, CoreJsonWebKeySet::new(Vec::new()));
    let mut request = client
        .authorize_url(
            CoreAuthenticationFlow::AuthorizationCode,
            || state,
            || nonce,
        )
        .set_pkce_challenge(challenge)
        .add_scope(Scope::new("profile".into()));
    if let Some(context) = context {
        request = request.add_extra_param(
            "claims",
            json!({
                "id_token": { "acrs": { "essential": true, "value": context } }
            })
            .to_string(),
        );
    }
    Ok((
        [(
            header::SET_COOKIE,
            browser_cookie(&workspace, &browser, 600),
        )],
        Json(json!({ "url": request.url().0.to_string() })),
    )
        .into_response())
}

#[derive(Deserialize)]
struct Callback {
    state: Option<String>,
    code: Option<String>,
}

struct Attempt {
    company: Uuid,
    tenant: Uuid,
    context: Option<String>,
    nonce: String,
    verifier: String,
}

#[derive(Clone, Debug, Deserialize, serde::Serialize)]
struct EntraClaims {
    tid: Uuid,
    oid: Uuid,
    #[serde(default)]
    acrs: Vec<String>,
    nbf: Option<i64>,
}

impl AdditionalClaims for EntraClaims {}

async fn complete(
    workspace: &Workspace,
    headers: &HeaderMap,
    input: Callback,
) -> Reply<(String, u32)> {
    let failure = || Rejection::unauthorized("Company sign-in could not be verified.");
    let entra = workspace.entra().ok_or_else(failure)?;
    let state = input
        .state
        .filter(|value| workspace::valid_key(value))
        .ok_or_else(failure)?;
    let browser = workspace::cookie_token(headers, BROWSER_COOKIE).ok_or_else(failure)?;
    let browser = workspace::key_digest(browser);
    let state = workspace::key_digest(&state);
    let attempt = workspace
        .query(move |database| {
            database
                .query_opt(
                    "SELECT * FROM ductdelta.web_take_entra($1, $2)",
                    &[&state, &browser],
                )?
                .map(|row| {
                    Ok(Attempt {
                        company: row.try_get(0)?,
                        tenant: row.try_get(1)?,
                        context: row.try_get(2)?,
                        nonce: row.try_get(3)?,
                        verifier: row.try_get(4)?,
                    })
                })
                .transpose()
        })
        .await?
        .ok_or_else(failure)?;
    let code = input
        .code
        .filter(|value| !value.is_empty() && value.len() <= 4096)
        .ok_or_else(failure)?;
    let key_url = JsonWebKeySetUrl::new(format!(
        "{}/discovery/v2.0/keys",
        entra.tenant_origin(attempt.tenant)
    ))
    .expect("valid signing key URL");
    let keys = CoreJsonWebKeySet::fetch_async(&key_url, &entra.http)
        .await
        .map_err(|_| failure())?;
    let client = entra.client(attempt.tenant, keys);
    let response = client
        .exchange_code(AuthorizationCode::new(code))
        .set_pkce_verifier(PkceCodeVerifier::new(attempt.verifier))
        .request_async(&entra.http)
        .await
        .map_err(|_| failure())?;
    let token: EntraToken = response
        .id_token()
        .ok_or_else(failure)?
        .to_string()
        .parse()
        .map_err(|_| failure())?;
    let verifier = client
        .id_token_verifier()
        .set_allowed_algs([CoreJwsSigningAlgorithm::RsaSsaPkcs1V15Sha256]);
    let claims = token
        .claims(&verifier, &Nonce::new(attempt.nonce))
        .map_err(|_| failure())?;
    let verified = claims.additional_claims();
    let now = time::OffsetDateTime::now_utc().unix_timestamp();
    if verified.tid != attempt.tenant
        || verified.oid.is_nil()
        || verified.nbf.is_some_and(|time| time > now + 60)
        || claims.issue_time().timestamp() > now + 60
    {
        return Err(failure());
    }
    let context = attempt
        .context
        .filter(|expected| verified.acrs.contains(expected));
    let lifetime = (claims.expiration().timestamp() - now).clamp(0, 3600) as i32;
    let session = workspace::random_key();
    let digest = workspace::key_digest(&session);
    let object = verified.oid;
    let accepted: bool = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_entra_login($1,$2,$3,$4,$5,$6)",
                    &[
                        &attempt.company,
                        &attempt.tenant,
                        &object,
                        &context,
                        &digest,
                        &lifetime,
                    ],
                )?
                .try_get(0)
        })
        .await?;
    if !accepted {
        return Err(failure());
    }
    Ok((session, lifetime as u32))
}

async fn callback(
    State(workspace): State<Workspace>,
    headers: HeaderMap,
    Query(input): Query<Callback>,
) -> Response {
    let result = complete(&workspace, &headers, input).await;
    let mut response = if result.is_ok() {
        Redirect::to("/").into_response()
    } else {
        Redirect::to("/?view=security&sso_error=1").into_response()
    };
    let headers = response.headers_mut();
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    if let Ok((token, lifetime)) = result {
        headers.append(header::SET_COOKIE, browser_cookie(&workspace, "", 0));
        headers.append(
            header::SET_COOKIE,
            workspace::session_cookie(&workspace, &token, lifetime),
        );
    }
    response
}

fn browser_cookie(workspace: &Workspace, token: &str, age: u32) -> HeaderValue {
    let secure = if workspace.origin().starts_with("https://") {
        "; Secure"
    } else {
        ""
    };
    HeaderValue::from_str(&format!(
        "{BROWSER_COOKIE}={token}; Path={CALLBACK}; HttpOnly; SameSite=Lax; Max-Age={age}{secure}"
    ))
    .expect("valid Entra browser cookie")
}
