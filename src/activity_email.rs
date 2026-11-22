//! Delivers signup and project activity alerts to the deployment operator.

use std::time::Duration;

use serde_json::json;
use uuid::Uuid;

use crate::email_layout::EmailLayout;
use crate::invitation_mailer::DeliveryOutcome;
use crate::invitation_mailer::DeliveryResult;
use crate::invitation_mailer::InvitationMailer;
use crate::invitation_mailer::Message;
use crate::workspace::Reply;
use crate::workspace::Workspace;

pub(crate) async fn deliver_queued(mailer: &InvitationMailer, workspace: &Workspace) {
    loop {
        match ActivityEmail::claim(workspace).await {
            Ok(Some(email)) => {
                let result = email.send(mailer).await;
                if email.finish(workspace, result).await.is_err() {
                    eprintln!("{{\"event\":\"activity_email_result_unsaved\"}}");
                }
            }
            Ok(None) => tokio::time::sleep(Duration::from_secs(2)).await,
            Err(_) => {
                eprintln!("{{\"event\":\"activity_email_queue_unavailable\"}}");
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        }
    }
}

struct ActivityEmail {
    id: Uuid,
    kind: String,
    recipient: String,
    sender: String,
    occurred_at: String,
    attempt: i32,
}

impl ActivityEmail {
    async fn claim(workspace: &Workspace) -> Reply<Option<Self>> {
        workspace
            .query(|database| {
                let Some(row) =
                    database.query_opt("SELECT * FROM ductdelta.claim_activity_email()", &[])?
                else {
                    return Ok(None);
                };
                Ok(Some(Self {
                    id: row.try_get("id")?,
                    kind: row.try_get("kind")?,
                    recipient: row.try_get("recipient")?,
                    sender: row.try_get("sender")?,
                    occurred_at: row.try_get("occurred_at")?,
                    attempt: row.try_get("attempt")?,
                }))
            })
            .await
    }

    async fn send(&self, mailer: &InvitationMailer) -> DeliveryResult {
        let summary = match self.kind.as_str() {
            "signup" => "new company signup",
            "invitation_accepted" => "invitation accepted",
            "project_created" => "new project",
            "change_opened" => "change case opened",
            "instruction" => "site instruction recorded",
            "decision" => "quote decision recorded",
            "certificate" => "certificate recorded",
            "receipt" => "payment receipt recorded",
            "close" => "change case closed",
            _ => return DeliveryResult::NeedsAttention,
        };
        let description = format!("DuctDelta recorded this activity: {summary}.");
        let detail = format!("Time: {}.", self.occurred_at);
        mailer
            .send(
                &format!("activity/{}", self.id),
                Message {
                    sender: &self.sender,
                    recipient: &self.recipient,
                    subject: &format!("DuctDelta: {summary}"),
                    text: &format!("{description}\n\n{detail}"),
                    layout: EmailLayout {
                        heading: "Workspace activity",
                        message: &description,
                        detail: &detail,
                        action: None,
                    },
                    reply_to: None,
                },
                self.attempt,
            )
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
                    "SELECT ductdelta.finish_activity_email($1, $2, $3, $4)",
                    &[&id, &attempt, &provider_id, &delay],
                )
            })
            .await?;
        eprintln!(
            "{}",
            json!({ "event": "activity_email_attempt", "id": id, "attempt": attempt, "state": state })
        );
        Ok(())
    }
}
