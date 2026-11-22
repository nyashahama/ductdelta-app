//! Delivers queued company invitations without holding up the onboarding request.

use std::env;
use std::fmt::Write as _;
use std::net::SocketAddr;
use std::time::Duration;

use axum::http::StatusCode;
use axum::http::Uri;
use axum::http::header;
use hmac::Hmac;
use hmac::KeyInit;
use hmac::Mac;
use reqwest::Client;
use serde::Deserialize;
use serde_json::Value;
use serde_json::json;
use sha2::Sha256;
use uuid::Uuid;

use crate::email_layout::EmailAction;
use crate::email_layout::EmailLayout;
use crate::workspace;
use crate::workspace::Rejection;
use crate::workspace::Reply;
use crate::workspace::Workspace;

const SEND_ENDPOINT: &str = "https://api.resend.com/emails";
const POLL_INTERVAL: Duration = Duration::from_millis(500);

pub(crate) struct InvitationMailer {
    client: Client,
    endpoint: String,
    api_key: String,
    signing_key: String,
    sender: String,
    reply_to: Option<String>,
}

impl InvitationMailer {
    pub(crate) fn from_env(secure: bool) -> Result<Option<Self>, &'static str> {
        let (key, sender, signing, endpoint) = (
            env::var_os("DUCTDELTA_RESEND_API_KEY"),
            env::var_os("DUCTDELTA_RESEND_FROM"),
            env::var_os("DUCTDELTA_INVITE_SIGNING_KEY"),
            env::var_os("DUCTDELTA_RESEND_API_URL"),
        );
        if [&key, &sender, &signing, &endpoint]
            .iter()
            .all(|value| value.is_none())
        {
            return Ok(None);
        }
        let api_key = key
            .and_then(|value| value.into_string().ok())
            .filter(|value| !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_graphic()))
            .ok_or("Set DUCTDELTA_RESEND_API_KEY for invitation email.")?;
        let sender = sender
            .and_then(|value| value.into_string().ok())
            .filter(|value| {
                value.contains('@') && value.len() <= 254 && !value.chars().any(char::is_control)
            })
            .ok_or("Set a verified DUCTDELTA_RESEND_FROM sender.")?;
        let signing_key = signing
            .and_then(|value| value.into_string().ok())
            .filter(|value| workspace::valid_key(value))
            .ok_or("Set a persistent random DUCTDELTA_INVITE_SIGNING_KEY with 64 hex digits.")?;
        let reply_to = env::var_os("DUCTDELTA_EMAIL_REPLY_TO")
            .map(|value| {
                value
                    .to_str()
                    .and_then(|value| mailbox(value).ok())
                    .ok_or("Set DUCTDELTA_EMAIL_REPLY_TO to one monitored support address.")
            })
            .transpose()?;
        let endpoint = match endpoint {
            None if secure => SEND_ENDPOINT.to_owned(),
            Some(value) if !secure => value
                .into_string()
                .ok()
                .filter(|value| loopback_endpoint(value))
                .ok_or("Use a numeric loopback email test endpoint.")?,
            _ => return Err("Invitation email requires an HTTPS origin for Resend."),
        };
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .timeout(Duration::from_secs(8))
            .build()
            .map_err(|_| "Could not start the invitation email client.")?;
        Ok(Some(Self {
            client,
            endpoint,
            api_key,
            signing_key,
            sender,
            reply_to,
        }))
    }

    pub(crate) fn sender(&self) -> &str {
        &self.sender
    }

    pub(crate) fn token(&self, id: Uuid) -> String {
        let mut mac = Hmac::<Sha256>::new_from_slice(self.signing_key.as_bytes())
            .expect("HMAC accepts a key of any size");
        mac.update(b"ductdelta invitation v1");
        mac.update(id.as_bytes());
        let mut token = String::with_capacity(64);
        for byte in mac.finalize().into_bytes() {
            write!(token, "{byte:02x}").expect("writing to a string cannot fail");
        }
        token
    }

    pub(crate) async fn deliver_queued(&self, workspace: &Workspace) {
        loop {
            match Delivery::claim(workspace).await {
                Ok(Some(delivery)) => {
                    let result = self.deliver(&delivery).await;
                    if delivery.finish(workspace, result).await.is_err() {
                        eprintln!("{{\"event\":\"invitation_email_result_unsaved\"}}");
                    }
                }
                Ok(None) => tokio::time::sleep(POLL_INTERVAL).await,
                Err(_) => {
                    eprintln!("{{\"event\":\"invitation_email_queue_unavailable\"}}");
                    tokio::time::sleep(Duration::from_secs(5)).await;
                }
            }
        }
    }

    async fn deliver(&self, delivery: &Delivery) -> DeliveryResult {
        let token = self.token(delivery.id);
        if workspace::key_digest(&token) != delivery.token_digest {
            return DeliveryResult::NeedsAttention;
        }
        let heading = "Join your team on DuctDelta";
        let description = format!(
            "{} invited you to join their DuctDelta workspace.",
            delivery.company_name
        );
        let url = format!("{}/#invite={token}", delivery.origin);
        let detail = "Use the invitation once before it expires. If you did not expect it, ignore this message.";
        let text = format!("{description}\n\n{url}\n\n{detail}");
        self.send(
            &format!("invitation/{}", delivery.id),
            Message {
                sender: &delivery.sender,
                recipient: &delivery.recipient,
                subject: heading,
                text: &text,
                layout: EmailLayout {
                    heading,
                    message: &description,
                    detail,
                    action: Some(EmailAction {
                        label: "Accept invitation",
                        url: &url,
                    }),
                },
                reply_to: self.reply_to.as_deref(),
            },
            delivery.attempt,
        )
        .await
    }

    pub(crate) async fn send(
        &self,
        idempotency_key: &str,
        message: Message<'_>,
        attempt: i32,
    ) -> DeliveryResult {
        let legacy = json!({
            "from": message.sender,
            "to": [message.recipient],
            "subject": message.subject,
            "text": message.text,
        });
        let mut payload = legacy.clone();
        payload["html"] = message.layout.render(message.reply_to).into();
        if let Some(reply_to) = message.reply_to {
            payload["reply_to"] = reply_to.into();
        }
        match self.send_payload(idempotency_key, &payload, attempt).await {
            Ok(result) => result,
            // Recover a delivery already sent by the plain-text release under the same key.
            Err(PayloadConflict) => self
                .send_payload(idempotency_key, &legacy, attempt)
                .await
                .unwrap_or(DeliveryResult::NeedsAttention),
        }
    }

    async fn send_payload(
        &self,
        idempotency_key: &str,
        payload: &Value,
        attempt: i32,
    ) -> Result<DeliveryResult, PayloadConflict> {
        let retry_after = 1 << attempt;
        let Ok(response) = self
            .client
            .post(&self.endpoint)
            .bearer_auth(&self.api_key)
            .header("Idempotency-Key", idempotency_key)
            .json(payload)
            .send()
            .await
        else {
            return Ok(DeliveryResult::Retry(retry_after));
        };

        let status = response.status();
        if status.is_success() {
            return Ok(match response.json::<Acceptance>().await {
                Ok(accepted) => DeliveryResult::Accepted(accepted.id),
                Err(_) => DeliveryResult::Retry(retry_after),
            });
        }
        if status.is_server_error() {
            return Ok(DeliveryResult::Retry(retry_after));
        }
        let retry_after = response
            .headers()
            .get(header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<i32>().ok())
            .map_or(retry_after, |delay| delay.clamp(retry_after, 86_400));
        if matches!(status, StatusCode::CONFLICT | StatusCode::TOO_MANY_REQUESTS) {
            let error = response.json::<ProviderError>().await.ok();
            let name = error.as_ref().map(|error| error.name.as_str());
            if status == StatusCode::CONFLICT && name == Some("invalid_idempotent_request") {
                return Err(PayloadConflict);
            }
            if matches!(
                (status, name),
                (StatusCode::CONFLICT, Some("concurrent_idempotent_requests"))
                    | (
                        StatusCode::TOO_MANY_REQUESTS,
                        Some("rate_limit_exceeded") | None
                    )
            ) {
                return Ok(DeliveryResult::Retry(retry_after));
            }
        }
        Ok(DeliveryResult::NeedsAttention)
    }
}

fn loopback_endpoint(value: &str) -> bool {
    let Ok(uri) = value.parse::<Uri>() else {
        return false;
    };
    uri.scheme_str() == Some("http")
        && uri
            .path_and_query()
            .is_some_and(|path| path.as_str() == "/emails")
        && uri
            .authority()
            .and_then(|authority| authority.as_str().parse::<SocketAddr>().ok())
            .is_some_and(|address| address.ip().is_loopback())
}

pub(crate) fn mailbox(value: &str) -> Reply<String> {
    let value = value.trim();
    let invalid = || Rejection::invalid("Enter one valid email address.");
    let (local, domain) = value.rsplit_once('@').ok_or_else(invalid)?;
    if value.len() > 254
        || local.is_empty()
        || local.len() > 64
        || local.starts_with('.')
        || local.ends_with('.')
        || local.contains("..")
        || !local
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b".!#$%&'*+-/=?^_`{|}~".contains(&byte))
        || !domain.contains('.')
        || !domain.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
    {
        return Err(invalid());
    }
    Ok(format!("{local}@{}", domain.to_ascii_lowercase()))
}

#[derive(Deserialize)]
struct Acceptance {
    id: Uuid,
}

#[derive(Deserialize)]
struct ProviderError {
    name: String,
}

struct PayloadConflict;

pub(crate) struct Message<'a> {
    pub(crate) sender: &'a str,
    pub(crate) recipient: &'a str,
    pub(crate) subject: &'a str,
    pub(crate) text: &'a str,
    pub(crate) layout: EmailLayout<'a>,
    pub(crate) reply_to: Option<&'a str>,
}

pub(crate) enum DeliveryResult {
    Accepted(Uuid),
    Retry(i32),
    NeedsAttention,
}

pub(crate) struct DeliveryOutcome {
    pub(crate) provider_id: Option<Uuid>,
    pub(crate) delay: Option<i32>,
    pub(crate) state: &'static str,
}

impl DeliveryResult {
    pub(crate) fn outcome(self, attempt: i32) -> DeliveryOutcome {
        let (provider_id, delay, state) = match self {
            Self::Accepted(id) => (Some(id), None, "accepted"),
            Self::Retry(delay) if attempt < 5 => (None, Some(delay), "retry"),
            Self::Retry(_) | Self::NeedsAttention => (None, None, "needs_attention"),
        };
        DeliveryOutcome {
            provider_id,
            delay,
            state,
        }
    }
}

struct Delivery {
    id: Uuid,
    recipient: String,
    sender: String,
    origin: String,
    company_name: String,
    token_digest: Vec<u8>,
    attempt: i32,
}

impl Delivery {
    async fn claim(workspace: &Workspace) -> Reply<Option<Self>> {
        workspace
            .query(|database| {
                let Some(row) =
                    database.query_opt("SELECT * FROM ductdelta.claim_invitation_email()", &[])?
                else {
                    return Ok(None);
                };
                Ok(Some(Self {
                    id: row.try_get("id")?,
                    recipient: row.try_get("recipient")?,
                    sender: row.try_get("sender")?,
                    origin: row.try_get("origin")?,
                    company_name: row.try_get("company_name")?,
                    token_digest: row.try_get("token_digest")?,
                    attempt: row.try_get("attempt")?,
                }))
            })
            .await
    }

    async fn finish(self, workspace: &Workspace, result: DeliveryResult) -> Reply<()> {
        let DeliveryOutcome {
            provider_id,
            delay,
            state,
        } = result.outcome(self.attempt);
        let id = self.id;
        let attempt = self.attempt;
        workspace
            .query(move |database| {
                database.execute(
                    "SELECT ductdelta.finish_invitation_email($1, $2, $3, $4)",
                    &[&id, &attempt, &provider_id, &delay],
                )
            })
            .await?;
        eprintln!(
            "{}",
            json!({ "event": "invitation_email_attempt", "id": id, "attempt": attempt, "state": state })
        );
        Ok(())
    }
}
