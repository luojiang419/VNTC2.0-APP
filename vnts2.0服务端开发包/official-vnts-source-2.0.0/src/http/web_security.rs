use axum::body::Body;
use axum::http::{HeaderMap, HeaderValue, Method, Request, header};
use axum::middleware::Next;
use axum::response::Response;
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub(crate) const SESSION_COOKIE: &str = "vnts_session";
pub(crate) const CSRF_HEADER: &str = "x-csrf-token";
const LOGIN_WINDOW: Duration = Duration::from_secs(5 * 60);
const LOGIN_BLOCK: Duration = Duration::from_secs(15 * 60);
const MAX_LOGIN_FAILURES: u8 = 5;
const MAX_TRACKED_SOURCES: usize = 4096;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Claims {
    pub(crate) sub: String,
    pub(crate) exp: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) csrf: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AuthError {
    Missing,
    Invalid,
    Csrf,
}

#[derive(Clone, Default)]
pub(crate) struct LoginLimiter {
    attempts: Arc<Mutex<HashMap<IpAddr, LoginAttempt>>>,
}

struct LoginAttempt {
    failures: u8,
    window_started: Instant,
    last_seen: Instant,
    blocked_until: Option<Instant>,
}

impl LoginLimiter {
    pub(crate) fn retry_after(&self, source: IpAddr) -> Option<u64> {
        let now = Instant::now();
        let mut attempts = self.attempts.lock();
        let attempt = attempts.get(&source)?;
        if let Some(blocked_until) = attempt.blocked_until
            && blocked_until > now
        {
            return Some(blocked_until.duration_since(now).as_secs().max(1));
        }
        if now.duration_since(attempt.window_started) >= LOGIN_WINDOW {
            attempts.remove(&source);
        }
        None
    }

    pub(crate) fn record_failure(&self, source: IpAddr) {
        let now = Instant::now();
        let mut attempts = self.attempts.lock();
        if !attempts.contains_key(&source)
            && attempts.len() >= MAX_TRACKED_SOURCES
            && let Some(oldest) = attempts
                .iter()
                .min_by_key(|(_, attempt)| attempt.last_seen)
                .map(|(source, _)| *source)
        {
            attempts.remove(&oldest);
        }
        let attempt = attempts.entry(source).or_insert(LoginAttempt {
            failures: 0,
            window_started: now,
            last_seen: now,
            blocked_until: None,
        });
        if now.duration_since(attempt.window_started) >= LOGIN_WINDOW {
            attempt.failures = 0;
            attempt.window_started = now;
            attempt.blocked_until = None;
        }
        attempt.last_seen = now;
        attempt.failures = attempt.failures.saturating_add(1);
        if attempt.failures >= MAX_LOGIN_FAILURES {
            attempt.blocked_until = Some(now + LOGIN_BLOCK);
        }
    }

    pub(crate) fn clear(&self, source: IpAddr) {
        self.attempts.lock().remove(&source);
    }
}

pub(crate) fn constant_time_eq(left: &str, right: &str) -> bool {
    let left = left.as_bytes();
    let right = right.as_bytes();
    let mut difference = left.len() ^ right.len();
    for index in 0..left.len().max(right.len()) {
        difference |= usize::from(
            left.get(index).copied().unwrap_or_default()
                ^ right.get(index).copied().unwrap_or_default(),
        );
    }
    difference == 0
}

pub(crate) fn authorize(
    headers: &HeaderMap,
    method: &Method,
    jwt_secret: &str,
) -> Result<Claims, AuthError> {
    let bearer = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    let cookie = bearer
        .is_none()
        .then(|| cookie_value(headers, SESSION_COOKIE))
        .flatten();
    let token = bearer.or(cookie).ok_or(AuthError::Missing)?;
    let claims = jsonwebtoken::decode::<Claims>(
        token,
        &DecodingKey::from_secret(jwt_secret.as_bytes()),
        &Validation::new(Algorithm::HS256),
    )
    .map_err(|_| AuthError::Invalid)?
    .claims;

    if bearer.is_none() && is_unsafe(method) {
        let expected = claims.csrf.as_deref().ok_or(AuthError::Csrf)?;
        let provided = headers
            .get(CSRF_HEADER)
            .and_then(|value| value.to_str().ok())
            .ok_or(AuthError::Csrf)?;
        if !constant_time_eq(expected, provided) {
            return Err(AuthError::Csrf);
        }
    }
    Ok(claims)
}

fn is_unsafe(method: &Method) -> bool {
    !matches!(method, &Method::GET | &Method::HEAD | &Method::OPTIONS)
}

fn cookie_value<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(';'))
        .filter_map(|cookie| cookie.trim().split_once('='))
        .find_map(|(cookie_name, value)| (cookie_name == name).then_some(value))
}

pub(crate) fn session_cookie(token: &str) -> String {
    format!("{SESSION_COOKIE}={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=86400")
}

pub(crate) fn expired_session_cookie() -> &'static str {
    "vnts_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
}

pub(crate) async fn security_headers(request: Request<Body>, next: Next) -> Response {
    let is_api = request.uri().path().starts_with("/api/");
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("x-frame-options", HeaderValue::from_static("DENY"));
    headers.insert("referrer-policy", HeaderValue::from_static("no-referrer"));
    headers.insert(
        "permissions-policy",
        HeaderValue::from_static("camera=(), microphone=(), geolocation=()"),
    );
    headers.insert(
        "cross-origin-opener-policy",
        HeaderValue::from_static("same-origin"),
    );
    headers.insert(
        "content-security-policy",
        HeaderValue::from_static(
            "default-src 'self'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; font-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
        ),
    );
    if is_api {
        headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
        headers.insert(header::PRAGMA, HeaderValue::from_static("no-cache"));
    }
    response
}

#[cfg(test)]
mod tests {
    use super::*;
    use jsonwebtoken::{EncodingKey, Header};

    #[test]
    fn cookie_auth_requires_csrf_only_for_unsafe_methods() {
        let secret = "test-secret";
        let token = jsonwebtoken::encode(
            &Header::default(),
            &Claims {
                sub: "admin".into(),
                exp: 4_102_444_800,
                csrf: Some("csrf-value".into()),
            },
            &EncodingKey::from_secret(secret.as_bytes()),
        )
        .unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            header::COOKIE,
            HeaderValue::from_str(&format!("{SESSION_COOKIE}={token}")).unwrap(),
        );
        assert!(authorize(&headers, &Method::GET, secret).is_ok());
        assert_eq!(
            authorize(&headers, &Method::POST, secret).unwrap_err(),
            AuthError::Csrf
        );
        headers.insert(CSRF_HEADER, HeaderValue::from_static("csrf-value"));
        assert!(authorize(&headers, &Method::POST, secret).is_ok());
    }

    #[test]
    fn bearer_auth_remains_compatible_without_csrf_claim() {
        let secret = "test-secret";
        let token = jsonwebtoken::encode(
            &Header::default(),
            &Claims {
                sub: "automation".into(),
                exp: 4_102_444_800,
                csrf: None,
            },
            &EncodingKey::from_secret(secret.as_bytes()),
        )
        .unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );
        assert!(authorize(&headers, &Method::DELETE, secret).is_ok());
    }

    #[test]
    fn login_limiter_blocks_after_five_failures_and_success_can_clear_state() {
        let limiter = LoginLimiter::default();
        let source: IpAddr = "192.0.2.10".parse().unwrap();
        for _ in 0..5 {
            assert!(limiter.retry_after(source).is_none());
            limiter.record_failure(source);
        }
        assert!(limiter.retry_after(source).is_some());
        limiter.clear(source);
        assert!(limiter.retry_after(source).is_none());
    }

    #[test]
    fn secret_comparison_includes_length_and_content() {
        assert!(constant_time_eq("same-secret", "same-secret"));
        assert!(!constant_time_eq("same-secret", "same-secreu"));
        assert!(!constant_time_eq("same-secret", "same-secret-longer"));
    }
}
