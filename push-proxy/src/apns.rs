use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow};
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use reqwest::{
    Client,
    header::{AUTHORIZATION, HeaderMap, HeaderValue},
};
use serde::Serialize;
use serde_json::Value;

const HOSTS: [&str; 2] = [
    "https://api.sandbox.push.apple.com",
    "https://api.push.apple.com",
];
const JWT_LIFETIME: Duration = Duration::from_secs(45 * 60);

#[derive(Default)]
struct State {
    auth: Option<(HeaderValue, Instant)>,
    token_env: HashMap<String, usize>,
}

pub struct Apns {
    http: Client,
    key: EncodingKey,
    header: Header,
    team_id: String,
    first: usize,
    state: Mutex<State>,
    #[cfg(test)]
    endpoints: Option<[String; 2]>,
}

impl Apns {
    pub fn new(
        key_path: &str,
        key_id: String,
        team_id: String,
        topic: String,
        sandbox: bool,
    ) -> Result<Self> {
        let pem = std::fs::read(key_path).context("Reading APNs signing key")?;
        let key = EncodingKey::from_ec_pem(&pem).context("Parsing APNs signing key")?;
        Self::with_key(key, key_id, team_id, topic, sandbox)
    }

    fn with_key(
        key: EncodingKey,
        key_id: String,
        team_id: String,
        topic: String,
        sandbox: bool,
    ) -> Result<Self> {
        let mut headers = HeaderMap::new();
        headers.insert(
            "apns-topic",
            HeaderValue::from_str(&topic).context("Invalid APNs topic")?,
        );
        headers.insert("apns-push-type", HeaderValue::from_static("alert"));
        headers.insert("apns-priority", HeaderValue::from_static("10"));
        let http = Client::builder()
            .http2_prior_knowledge()
            .timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .default_headers(headers)
            .build()
            .context("Building APNs HTTP client")?;
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(key_id);
        Ok(Self {
            http,
            key,
            header,
            team_id,
            first: usize::from(!sandbox),
            state: Mutex::new(State::default()),
            #[cfg(test)]
            endpoints: None,
        })
    }

    fn auth(&self) -> Result<HeaderValue> {
        #[derive(Serialize)]
        struct Claims<'a> {
            iss: &'a str,
            iat: u64,
        }

        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow!("APNs cache lock poisoned"))?;
        if let Some((auth, created)) = &state.auth
            && created.elapsed() < JWT_LIFETIME
        {
            return Ok(auth.clone());
        }
        let claims = Claims {
            iss: &self.team_id,
            iat: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .context("System clock precedes Unix epoch")?
                .as_secs(),
        };
        let jwt = jsonwebtoken::encode(&self.header, &claims, &self.key)
            .context("Signing APNs authentication token")?;
        let mut auth = HeaderValue::from_str(&format!("bearer {jwt}"))
            .context("Building APNs authorization header")?;
        auth.set_sensitive(true);
        state.auth = Some((auth.clone(), Instant::now()));
        Ok(auth)
    }

    pub async fn push(&self, token: &str, payload: &Value) -> Result<u16> {
        let first = self
            .state
            .lock()
            .map_err(|_| anyhow!("APNs cache lock poisoned"))?
            .token_env
            .get(token)
            .copied()
            .unwrap_or(self.first);
        let mut status = 400;
        for env in [first, 1 - first] {
            let host = HOSTS[env];
            #[cfg(test)]
            let host = self
                .endpoints
                .as_ref()
                .map_or(host, |hosts| hosts[env].as_str());
            let response = self
                .http
                .post(format!("{host}/3/device/{token}"))
                .header(AUTHORIZATION, self.auth()?)
                .json(payload)
                .send()
                .await
                // reqwest URLs contain the full device token; never propagate them into logs.
                .map_err(|error| error.without_url())
                .context("Sending APNs request")?;
            status = response.status().as_u16();
            if status == 200 {
                let mut state = self
                    .state
                    .lock()
                    .map_err(|_| anyhow!("APNs cache lock poisoned"))?;
                if state.token_env.get(token) != Some(&env) {
                    state.token_env.insert(token.to_owned(), env);
                }
                return Ok(status);
            }
            let body = response
                .bytes()
                .await
                .map_err(|error| error.without_url())
                .context("Reading APNs response")?;
            let bad_token = serde_json::from_slice::<Value>(&body)
                .ok()
                .and_then(|body| body.get("reason").map(|reason| reason == "BadDeviceToken"))
                .unwrap_or(false);
            if !bad_token {
                // Error bodies are untrusted and can contain tokens or notification content.
                log::warn!(
                    "APNs status {status} ({})",
                    if env == 0 { "sandbox" } else { "production" }
                );
                return Ok(status);
            }
        }
        log::warn!("APNs BadDeviceToken on both environments");
        Ok(status)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use http::{Request, Response, Version};
    use jsonwebtoken::{DecodingKey, Validation};
    use tokio::{net::TcpListener, sync::mpsc, task::JoinHandle};

    // Generated fixture key: never used outside these local tests.
    const KEY: &[u8] = b"-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg1tfK0b1Ozi+tqkE+\nns/1WmmhXMEACt6q8xD5YqQBHR6hRANCAARSQYLkz5LZjjBXzOSYcW9ruA/hPbmk\njyMosD3YtxHuGD+c9j39Y7CuYVybWPqFZuKO1YIa6phO/bZ1+yeFrMxw\n-----END PRIVATE KEY-----\n";
    const PUBLIC_KEY: &[u8] = b"-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUkGC5M+S2Y4wV8zkmHFva7gP4T25\npI8jKLA92LcR7hg/nPY9/WOwrmFcm1j6hWbijtWCGuqYTv22dfsnhazMcA==\n-----END PUBLIC KEY-----\n";
    const TOKEN: &str = "abababababababababababababababababababababababababababababababab";
    const BAD_TOKEN: &str = r#"{"reason":"BadDeviceToken"}"#;

    struct Server {
        url: String,
        requests: mpsc::UnboundedReceiver<Request<Vec<u8>>>,
        task: JoinHandle<()>,
    }

    impl Drop for Server {
        fn drop(&mut self) {
            self.task.abort();
        }
    }

    async fn server(responses: Vec<(u16, &'static str)>) -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (sender, requests) = mpsc::unbounded_channel();
        let task = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut connection = h2::server::handshake(socket).await.unwrap();
            let mut responses = responses.into_iter();
            while let Some(request) = connection.accept().await {
                let (request, mut respond) = request.unwrap();
                let (status, body) = responses.next().expect("unexpected extra APNs request");
                let sender = sender.clone();
                tokio::spawn(async move {
                    let (parts, mut stream) = request.into_parts();
                    let mut payload = Vec::new();
                    while let Some(chunk) = stream.data().await {
                        let chunk = chunk.unwrap();
                        payload.extend_from_slice(&chunk);
                        stream.flow_control().release_capacity(chunk.len()).unwrap();
                    }
                    sender.send(Request::from_parts(parts, payload)).unwrap();
                    let response = Response::builder()
                        .status(status)
                        .header("location", "http://127.0.0.1:9/must-not-follow")
                        .body(())
                        .unwrap();
                    respond
                        .send_response(response, false)
                        .unwrap()
                        .send_data(Bytes::from_static(body.as_bytes()), true)
                        .unwrap();
                });
            }
        });
        Server {
            url,
            requests,
            task,
        }
    }

    fn client(sandbox: &Server, production: &Server, prefer_sandbox: bool) -> Apns {
        let mut apns = Apns::with_key(
            EncodingKey::from_ec_pem(KEY).unwrap(),
            "TEST_KEY".into(),
            "TEST_TEAM".into(),
            "me.anemoneya.gecko".into(),
            prefer_sandbox,
        )
        .unwrap();
        apns.endpoints = Some([sandbox.url.clone(), production.url.clone()]);
        apns
    }

    #[tokio::test]
    async fn http2_fallback_learning_headers_payload_and_signed_jwt() {
        let mut sandbox = server(vec![(400, BAD_TOKEN), (200, "")]).await;
        let mut production = server(vec![(200, ""), (200, "")]).await;
        let apns = client(&sandbox, &production, true);
        let payload = serde_json::json!({"aps": {"alert": "Test", "mutable-content": 1}});
        assert_eq!(apns.push(TOKEN, &payload).await.unwrap(), 200);
        let request = sandbox.requests.recv().await.unwrap();
        assert_eq!(request.version(), Version::HTTP_2);
        assert_eq!(request.method(), "POST");
        assert_eq!(request.uri().path(), format!("/3/device/{TOKEN}"));
        assert_eq!(request.headers()["apns-topic"], "me.anemoneya.gecko");
        assert_eq!(request.headers()["apns-push-type"], "alert");
        assert_eq!(request.headers()["apns-priority"], "10");
        assert_eq!(
            serde_json::from_slice::<Value>(request.body()).unwrap(),
            payload
        );
        let auth = request.headers()[AUTHORIZATION].to_str().unwrap();
        let jwt = auth.strip_prefix("bearer ").unwrap();
        let mut validation = Validation::new(Algorithm::ES256);
        validation.required_spec_claims.clear();
        validation.validate_exp = false;
        validation.set_issuer(&["TEST_TEAM"]);
        let decoded = jsonwebtoken::decode::<Value>(
            jwt,
            &DecodingKey::from_ec_pem(PUBLIC_KEY).unwrap(),
            &validation,
        )
        .unwrap();
        assert_eq!(decoded.header.kid.as_deref(), Some("TEST_KEY"));
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert!(now.abs_diff(decoded.claims["iat"].as_u64().unwrap()) < 10);
        let fallback = production.requests.recv().await.unwrap();
        assert_eq!(
            fallback.headers()[AUTHORIZATION],
            request.headers()[AUTHORIZATION]
        );
        assert_eq!(apns.push(TOKEN, &payload).await.unwrap(), 200);
        production.requests.recv().await.unwrap();
        assert!(sandbox.requests.try_recv().is_err());
        assert_eq!(apns.state.lock().unwrap().token_env[TOKEN], 1);
        // Learning is per token: a new token still starts in the configured environment.
        assert_eq!(apns.push(&"cd".repeat(32), &payload).await.unwrap(), 200);
        sandbox.requests.recv().await.unwrap();
        assert!(production.requests.try_recv().is_err());
    }

    #[tokio::test]
    async fn production_preference_and_exhausted_fallback() {
        let mut sandbox = server(vec![(400, BAD_TOKEN)]).await;
        let mut production = server(vec![(200, ""), (400, BAD_TOKEN)]).await;
        let apns = client(&sandbox, &production, false);
        assert_eq!(apns.push(TOKEN, &Value::Null).await.unwrap(), 200);
        production.requests.recv().await.unwrap();
        assert!(sandbox.requests.try_recv().is_err());
        let other = "cd".repeat(32);
        assert_eq!(apns.push(&other, &Value::Null).await.unwrap(), 400);
        production.requests.recv().await.unwrap();
        sandbox.requests.recv().await.unwrap();
        assert!(!apns.state.lock().unwrap().token_env.contains_key(&other));
    }

    #[tokio::test]
    async fn non_token_errors_malformed_bodies_and_redirects_never_fall_back() {
        let cases = vec![
            (410, r#"{"reason":"Unregistered"}"#),
            (403, r#"{"reason":"ExpiredProviderToken"}"#),
            (500, "not JSON"),
            (400, "[]"),
            (400, "null"),
            (400, r#"{"reason":42}"#),
            (307, ""),
        ];
        let mut sandbox = server(cases.clone()).await;
        let mut production = server(vec![]).await;
        let apns = client(&sandbox, &production, true);
        for (status, _) in cases {
            assert_eq!(apns.push(TOKEN, &Value::Null).await.unwrap(), status);
            sandbox.requests.recv().await.unwrap();
        }
        assert!(production.requests.try_recv().is_err());
        assert!(apns.state.lock().unwrap().token_env.is_empty());
    }

    #[tokio::test]
    async fn authentication_cache_expires_after_45_minutes() {
        let sandbox = server(vec![]).await;
        let production = server(vec![]).await;
        let apns = client(&sandbox, &production, true);
        let auth = apns.auth().unwrap();
        assert!(auth.is_sensitive());
        assert_eq!(auth, apns.auth().unwrap());
        {
            let mut state = apns.state.lock().unwrap();
            state.auth = Some((
                HeaderValue::from_static("expired"),
                Instant::now() - JWT_LIFETIME,
            ));
        }
        assert_ne!(apns.auth().unwrap(), "expired");
        assert!(
            apns.state
                .lock()
                .unwrap()
                .auth
                .as_ref()
                .unwrap()
                .1
                .elapsed()
                < Duration::from_secs(1)
        );
    }

    #[tokio::test]
    async fn network_errors_do_not_expose_token_or_try_other_environment() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let closed_url = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let sandbox = server(vec![]).await;
        let mut production = server(vec![]).await;
        let mut apns = client(&sandbox, &production, true);
        apns.endpoints.as_mut().unwrap()[0] = closed_url;
        let error = apns.push(TOKEN, &Value::Null).await.unwrap_err();
        assert!(!format!("{error:#}").contains(TOKEN));
        assert!(!format!("{error:?}").contains(TOKEN));
        assert!(production.requests.try_recv().is_err());
    }
}
