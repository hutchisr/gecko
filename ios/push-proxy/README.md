# Gecko push proxy

A standalone Rust binary translating XEP-0357 publishes into APNs notifications.
Runs as an ordinary XMPP bot account — no server component, registration API,
database, or message queue. The app and Notification Service Extension protocols
are unchanged.

## Push flow

1. Gecko registers with APNs and obtains a device token.
2. Gecko sends `<enable xmlns='urn:xmpp:push:0' jid='BOT_JID' node='TOKEN'/>`
   to its XMPP server, then sends notification filters to the bot.
3. The server delivers an IQ-set pubsub publish to the bot's **full JID with a
   fixed resource**, for example `geckopush@example.org/proxy`. A bare JID does
   not route these IQs to the bot. The publish node is the APNs device token.
4. The proxy acknowledges the IQ, applies the filters, and sends a generic
   alert and summary badge to APNs. The NSE fetches/decrypts on-device, enriches
   the alert, and corrects the badge from the app store's unread count.

## Running

Requires a current stable Rust toolchain. From this directory:

```sh
cargo build --release --locked
XMPP_JID=geckopush@example.org/proxy \
XMPP_PASSWORD=... \
APNS_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8 \
APNS_KEY_ID=XXXXXXXXXX \
APNS_TEAM_ID=998J34UYP5 \
APNS_TOPIC=me.anemoneya.gecko \
APNS_SANDBOX=1 \
XMPP_PING_INTERVAL=60 \
XMPP_PING_TIMEOUT=15 \
./target/release/gecko-push-proxy
```

`XMPP_JID`, `XMPP_PASSWORD`, `APNS_KEY_PATH`, `APNS_KEY_ID`, and `APNS_TEAM_ID`
are required. `APNS_TOPIC` defaults to `me.anemoneya.gecko`.

`APNS_SANDBOX` selects the first environment (`1`, the default, for sandbox;
`0` for production). Only `BadDeviceToken` triggers a second attempt in the
other environment. The working environment is cached per token. Ad-hoc,
TestFlight, and App Store builds use production; development builds use sandbox.
APNs requests use HTTP/2, verified TLS, a ten-second timeout, and ES256 provider
JWTs refreshed after 45 minutes. Redirects and automatic HTTP retries are disabled.

XMPP uses DNS SRV discovery, verified STARTTLS, SASL authentication, and
XEP-0198 stream management when offered. **Liveness probes now use the library's
idle-stream timer**, rather than Python's periodic ping task: after
`XMPP_PING_INTERVAL` seconds without incoming data, send a stream-management
acknowledgement request (or an XEP-0199 ping without stream management).
`XMPP_PING_TIMEOUT` seconds of further silence forces reconnection. Setting
either value to zero disables idle probes. Defaults are 60 and 15 seconds.
Reconnect backoff starts at `XMPP_RECONNECT_INITIAL` (default 1 second) and
caps at `XMPP_RECONNECT_MAX` (default 60 seconds). SIGINT/SIGTERM close the
XMPP stream and allow up to five seconds for in-flight APNs requests to finish.

## Notification behavior and limits

- Bodiless publishes are dropped, including typing, receipts, and the server's
  bodiless message twin. This deliberately also misses real encrypted messages
  whose summaries omit a fallback body. Every body-bearing publish is independent;
  there is no time-window deduplication.
- Muted conversations and messages without the configured mention send only a
  badge. Mention matching remains a case-insensitive substring check, not an
  attempt to decrypt OMEMO on the proxy.
- Servers may include sender/body summary fields. They are used for filtering,
  but never forwarded to APNs; alert text is generic. The NSE owns decryption.
- Filters arrive in `urn:gecko:push:filters` JSON messages; existing body-based
  filter messages are also understood. Tokens must be 32–200 ASCII hex characters.
  Malformed updates leave the previous rules intact.
- Filters and learned APNs environments survive XMPP reconnects but are only
  in memory. After a process restart, open/reconnect Gecko so it resends filters.
- IQ acknowledgement precedes APNs delivery, as before. An APNs failure is
  logged, not durably queued or retried. At most 64 requests are in flight;
  incoming stanzas are backpressured while those requests finish.
- The device token remains the routing/filter capability; this does not introduce
  an account-registration or token-ownership authentication protocol.

## Checks

```sh
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --check
```

Tests cover XML/JSON boundaries, badges and filtering, independent publishes,
SCRAM mechanism selection, IQ routing, and reconnect backoff. Local HTTP/2
servers exercise the real APNs client, verify its ES256 JWT signature and
headers, and cover environment fallback, caching, malformed errors, redirects,
and error redaction. Tests require no XMPP account or Apple credentials.

The replacement was also smoke-run as an actual process against an isolated
STARTTLS/SCRAM-SHA-256 server: fixed-resource login, IQ responses, bodiless
suppression, stale-connection recovery with and without stream management,
XEP-0198 resumption, and SIGTERM shutdown. The production rollout additionally
verified XMPP ping/publish round trips through `xmpp.is` and the deployed Rust
client's APNs sandbox/production fallback: a synthetic token received the expected
`BadDeviceToken` rejection from both environments. No real-device banner was
sent or verified by that probe.

## Docker / Kubernetes

```sh
docker build -t gecko-push-proxy .
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v /path/to/AuthKey_XXXXXXXXXX.p8:/secrets/apns.p8:ro \
  -e XMPP_JID='geckopush@example.org/proxy' -e XMPP_PASSWORD=... \
  -e APNS_KEY_PATH=/secrets/apns.p8 -e APNS_KEY_ID=... -e APNS_TEAM_ID=... \
  gecko-push-proxy
```

The multi-stage image contains the release binary, CA certificates, and the
proxy's MIT license, and defaults to `nobody`. The local Docker example overrides
the user with your UID/GID so an owned `0600` signing key remains readable without
making it world-readable; the mount stays read-only. Kubernetes uses its existing
Secret mount permissions. The build context excludes local keys, virtual
environments, and build artifacts.

`k8s.yaml` retains one replica and `Recreate`: never run competing instances
with the same fixed XMPP resource. It pins the published Linux/AMD64
`rust-20261103` image by digest.

Production on `admin@fortuna` is managed by Helm release `gecko-services` in
namespace `gecko`, using the sibling infrastructure repository's
`fortuna/gecko-services` chart and `push.image` value. Update that value and
upgrade the Helm release; do not apply the standalone manifest over it.
The Rust rollout is Helm revision 4; revision 3 retains the previous Python
image for rollback:

```sh
helm --kube-context admin@fortuna -n gecko rollback gecko-services 3 --wait --timeout 3m
```

If rolling back, also restore the infrastructure repository's `push.image`
value so the next Helmfile sync does not redeploy Rust. Existing secrets,
mounted key, namespace, and app `DINO_PUSH_PROXY_JID` remain compatible.
Open/reconnect Gecko after a proxy restart to repopulate notification filters.

## License

The repository-owned code and documentation in `ios/push-proxy/` are licensed
under the [MIT License](LICENSE), independently of Gecko's root GPL license.
Third-party dependencies retain their own licenses; MIT does not relicense them.
