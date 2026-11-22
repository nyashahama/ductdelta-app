//! Shared HTML layout for transactional email.

pub(crate) struct EmailLayout<'a> {
    pub(crate) heading: &'a str,
    pub(crate) message: &'a str,
    pub(crate) detail: &'a str,
    pub(crate) action: Option<EmailAction<'a>>,
}

pub(crate) struct EmailAction<'a> {
    pub(crate) label: &'a str,
    pub(crate) url: &'a str,
}

impl EmailLayout<'_> {
    pub(crate) fn render(&self, reply_to: Option<&str>) -> String {
        let action = self.action.as_ref().map_or_else(String::new, |action| {
            format!(
                concat!(
                    r#"<table role="presentation" cellspacing="0" cellpadding="0" border="0" "#,
                    r##"style="margin:24px 0"><tr><td bgcolor="#166534" style="border-radius:6px">"##,
                    r#"<a href="{}" style="display:inline-block;border:12px solid #166534;"#,
                    r#"padding:0 8px;color:#ffffff;font-size:16px;line-height:20px;font-weight:bold;"#,
                    r#"text-decoration:none;border-radius:6px">{}</a></td></tr></table>"#,
                ),
                escape(action.url),
                escape(action.label),
            )
        });
        let support = reply_to.map_or_else(String::new, |address| {
            let address = escape(address);
            format!(
                concat!(
                    r#"<p style="margin:4px 0 0">Need help? Reply here or email "#,
                    r#"<a href="mailto:{address}" style="color:#166534">{address}</a>.</p>"#,
                ),
                address = address,
            )
        });
        format!(
            include_str!("email_layout.html"),
            heading = escape(self.heading),
            message = escape(self.message),
            detail = escape(self.detail),
            action = action,
            support = support,
        )
    }
}

fn escape(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    for character in input.chars() {
        match character {
            '&' => output.push_str("&amp;"),
            '<' => output.push_str("&lt;"),
            '>' => output.push_str("&gt;"),
            '"' => output.push_str("&quot;"),
            '\'' => output.push_str("&#39;"),
            _ => output.push(character),
        }
    }
    output
}
