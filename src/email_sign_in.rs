//! Passwordless sign-in and verified email enrollment.

use std::time::Duration;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::{Json, Router, routing};
use serde::Deserialize;
use serde_json::{Value, json};
use subtle::ConstantTimeEq;
use uuid::Uuid;

use crate::company_setup::checked_name;
use crate::email_layout::EmailLayout;
use crate::invitation_mailer::{InvitationMailer, Message, mailbox};
use crate::workspace::{self, Rejection, Reply, Workspace};

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/account/email-sign-in", routing::get(policy))
        .route("/api/account/email-codes", routing::post(request_code))
        .route("/api/account/email-codes/verify", routing::post(verify))
        .route("/api/account/security", routing::get(security))
        .route(
            "/api/account/security/recovery-code",
            routing::post(rotate_recovery),
        )
}

async fn security(State(workspace): State<Workspace>, headers: HeaderMap) -> Reply<Json<Value>> {
    let session = workspace::session(&headers)?;
    let value = workspace
        .query(move |database| {
            database
                .query_one("SELECT ductdelta.web_email_security($1)", &[&session])?
                .try_get(0)
        })
        .await?;
    Ok(Json(value))
}

async fn rotate_recovery(
    State(workspace): State<Workspace>,
    headers: HeaderMap,
) -> Reply<(StatusCode, Json<Value>)> {
    let session = workspace::session(&headers)?;
    let code = workspace::random_key();
    let digest = workspace::key_digest(&code);
    workspace
        .query(move |database| {
            database.execute(
                "SELECT ductdelta.web_rotate_email_recovery($1, $2)",
                &[&session, &digest],
            )
        })
        .await?;
    Ok((StatusCode::CREATED, Json(json!({ "code": code }))))
}

async fn policy(State(workspace): State<Workspace>) -> Json<Value> {
    Json(json!({ "enabled": workspace.email_sign_in() }))
}

#[derive(Deserialize)]
struct CodeRequest {
    id: Option<Uuid>,
    email: String,
    #[serde(flatten)]
    purpose: Purpose,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case", tag = "purpose")]
enum Purpose {
    SignIn,
    Company {
        company: String,
        name: String,
        setup_code: Option<String>,
    },
    Invite {
        token: String,
    },
    Upgrade {
        key: String,
        token: Option<String>,
    },
    Recover {
        key: String,
    },
}

fn mailer(workspace: &Workspace) -> Reply<&InvitationMailer> {
    workspace
        .invitation_mailer()
        .filter(|_| workspace.email_sign_in())
        .ok_or_else(|| Rejection::unavailable("Email sign-in is unavailable."))
}

async fn request_code(
    State(workspace): State<Workspace>,
    Json(input): Json<CodeRequest>,
) -> Reply<(StatusCode, Json<Value>)> {
    let mailer = mailer(&workspace)?;
    let email = mailbox(&input.email)?;
    let (purpose, company, name, invitation, legacy) = match input.purpose {
        Purpose::SignIn => ("sign_in", None, None, None, None),
        Purpose::Company {
            company,
            name,
            setup_code,
        } => {
            workspace.check_company_setup_code(setup_code.as_deref())?;
            (
                "company",
                Some(checked_name(&company)?.to_owned()),
                Some(checked_name(&name)?.to_owned()),
                None,
                None,
            )
        }
        Purpose::Invite { token } if workspace::valid_key(&token) => (
            "invite",
            None,
            None,
            Some(workspace::key_digest(&token)),
            None,
        ),
        Purpose::Invite { .. } => return Err(Rejection::invalid("This invitation is invalid.")),
        Purpose::Upgrade { key, token } if workspace::valid_key(&key) => {
            if token
                .as_deref()
                .is_some_and(|value| !workspace::valid_key(value))
            {
                return Err(Rejection::invalid("This invitation is invalid."));
            }
            (
                "upgrade",
                None,
                None,
                token.as_deref().map(workspace::key_digest),
                Some(workspace::key_digest(&key)),
            )
        }
        Purpose::Upgrade { .. } => {
            return Err(Rejection::invalid(
                "Enter your existing access or recovery key.",
            ));
        }
        Purpose::Recover { key } if workspace::valid_key(&key) => (
            "recover",
            None,
            None,
            None,
            Some(workspace::key_digest(&key)),
        ),
        Purpose::Recover { .. } => {
            return Err(Rejection::invalid(
                "Enter your saved account recovery code.",
            ));
        }
    };
    let id = input.id.unwrap_or_else(Uuid::new_v4);
    // A fresh server-side ID prevents reusing a code if the client retries an
    // identifier whose previous challenge has already been purged.
    let delivery_id = Uuid::new_v4();
    let digest = code_digest(mailer, id, &code_for(mailer, delivery_id));
    workspace
        .query(move |database| {
            database.execute(
                "SELECT ductdelta.web_request_email_code($1, $2, $3, $4, $5, $6, $7, $8, $9)",
                &[
                    &id,
                    &delivery_id,
                    &email,
                    &digest.as_slice(),
                    &purpose,
                    &company,
                    &name,
                    &invitation,
                    &legacy,
                ],
            )
        })
        .await?;
    Ok((StatusCode::ACCEPTED, Json(json!({ "id": id }))))
}

#[derive(Deserialize)]
struct Verification {
    id: Uuid,
    code: String,
}

async fn verify(
    State(workspace): State<Workspace>,
    Json(input): Json<Verification>,
) -> Reply<Response> {
    let mailer = mailer(&workspace)?;
    let supplied = input.code.trim();
    if supplied.len() != 8 || !supplied.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(Rejection::invalid(
            "Enter the eight-digit code from your email.",
        ));
    }
    let proof = code_digest(mailer, input.id, supplied);
    let token = workspace::random_key();
    let session = workspace::key_digest(&token);
    let accepted: bool = workspace
        .query(move |database| {
            database
                .query_one(
                    "SELECT ductdelta.web_verify_email_code($1, $2, $3)",
                    &[&input.id, &proof.as_slice(), &session],
                )?
                .try_get(0)
        })
        .await?;
    if !accepted {
        return Err(Rejection::unauthorized(
            "This code is invalid or has expired. You can request a new one.",
        ));
    }
    Ok((
        StatusCode::NO_CONTENT,
        [(
            header::SET_COOKIE,
            workspace::session_cookie(&workspace, &token, 43_200),
        )],
    )
        .into_response())
}

fn code_for(mailer: &InvitationMailer, delivery_id: Uuid) -> String {
    let digest = mailer.keyed_digest(b"ductdelta email code v1", delivery_id, b"");
    let value = u64::from_be_bytes(digest[..8].try_into().expect("eight bytes"));
    format!("{:08}", value % 100_000_000)
}

fn code_digest(mailer: &InvitationMailer, id: Uuid, code: &str) -> [u8; 32] {
    mailer.keyed_digest(b"ductdelta email proof v1", id, code.as_bytes())
}

struct Delivery {
    id: Uuid,
    delivery_id: Uuid,
    email: String,
    digest: Vec<u8>,
    attempt: i32,
    notification: bool,
}

impl Delivery {
    async fn claim(workspace: &Workspace) -> Reply<Option<Self>> {
        workspace
            .query(|database| {
                database
                    .query_opt("SELECT * FROM ductdelta.claim_email_code()", &[])?
                    .map(|row| {
                        Ok(Self {
                            id: row.try_get("id")?,
                            delivery_id: row.try_get("delivery_id")?,
                            email: row.try_get("email")?,
                            digest: row.try_get("digest")?,
                            attempt: row.try_get("attempt")?,
                            notification: row.try_get("notification")?,
                        })
                    })
                    .transpose()
            })
            .await
    }

    async fn send(self, mailer: &InvitationMailer, workspace: &Workspace) -> Reply<()> {
        let code = code_for(mailer, self.delivery_id);
        let proof = code_digest(mailer, self.id, &code);
        let mut delay = None;
        if self.notification || bool::from(proof.as_slice().ct_eq(&self.digest)) {
            let (kind, subject, message, detail) = if self.notification {
                (
                    "email-notice",
                    "Your DuctDelta sign-in email changed",
                    "The sign-in email for your DuctDelta account was changed.".to_owned(),
                    "If you did not make this change, contact your company administrator.",
                )
            } else {
                (
                    "email-code",
                    "Your DuctDelta sign-in code",
                    format!("Your code is {code}."),
                    "This code expires 10 minutes after you request it. If you did not ask for a code, ignore this email.",
                )
            };
            let text = format!("{message}\n\n{detail}");
            let result = mailer
                .send(
                    &format!("{kind}/{}/{}", self.id, self.delivery_id),
                    Message {
                        sender: mailer.sender(),
                        recipient: &self.email,
                        subject,
                        text: &text,
                        layout: EmailLayout {
                            heading: subject,
                            message: &message,
                            detail,
                            action: None,
                        },
                        reply_to: None,
                    },
                    self.attempt,
                )
                .await
                .outcome(self.attempt);
            delay = result.delay;
            eprintln!(
                "{}",
                json!({ "event": "email_code_delivery", "id": self.id, "state": result.state })
            );
        }

        workspace
            .query(move |database| {
                database.execute(
                    "SELECT ductdelta.finish_email_code($1, $2, $3, $4)",
                    &[&self.id, &self.delivery_id, &self.attempt, &delay],
                )
            })
            .await?;
        Ok(())
    }
}

pub(crate) async fn deliver_queued(mailer: &InvitationMailer, workspace: &Workspace) {
    loop {
        match Delivery::claim(workspace).await {
            Ok(Some(delivery)) => {
                if delivery.send(mailer, workspace).await.is_err() {
                    eprintln!(
                        "{}",
                        json!({ "event": "email_code_delivery_result_unsaved" })
                    );
                }
            }
            Ok(None) => tokio::time::sleep(Duration::from_millis(500)).await,
            Err(_) => {
                eprintln!("{}", json!({ "event": "email_code_queue_unavailable" }));
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        }
    }
}
