//! Correlates HTTP responses with request timing without logging request data.

use std::env;
use std::io;
use std::io::Write as _;
use std::time::Instant;

use axum::extract::MatchedPath;
use axum::extract::Request;
use axum::http::HeaderValue;
use axum::middleware::Next;
use axum::response::Response;
use serde_json::json;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

pub(crate) fn enabled(secure: bool) -> Result<bool, &'static str> {
    match env::var("DUCTDELTA_TRACE_REQUESTS").as_deref() {
        Ok("1") => Ok(true),
        Ok("0") => Ok(false),
        Err(env::VarError::NotPresent) => Ok(secure),
        _ => Err("Set DUCTDELTA_TRACE_REQUESTS to 1 or 0."),
    }
}

pub(crate) async fn record(enabled: bool, request: Request, next: Next) -> Response {
    let called_at = Instant::now();
    let request_id = Uuid::new_v4();
    let route = request.extensions().get::<MatchedPath>().cloned();
    let method = match request.method().as_str() {
        "GET" => "GET",
        "HEAD" => "HEAD",
        "POST" => "POST",
        "PUT" => "PUT",
        "PATCH" => "PATCH",
        "DELETE" => "DELETE",
        "OPTIONS" => "OPTIONS",
        _ => "OTHER",
    };
    let mut response = next.run(request).await;
    response.headers_mut().insert(
        "x-request-id",
        HeaderValue::try_from(request_id.to_string()).expect("a UUID is a valid header value"),
    );
    if enabled {
        let entry = json!({
            "event": "http_request",
            "timestamp": OffsetDateTime::now_utc().format(&Rfc3339).ok(),
            "request_id": request_id,
            "method": method,
            "route": route.as_ref().map_or("unmatched", MatchedPath::as_str),
            "status": response.status().as_u16(),
            "elapsed_ms": called_at.elapsed().as_secs_f64() * 1000.0,
        });
        let _ = writeln!(io::stderr().lock(), "{entry}");
    }
    response
}
