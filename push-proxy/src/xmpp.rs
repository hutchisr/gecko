use crate::{Config, apns::Apns, protocol};
use anyhow::{Context, Result, bail};
use futures::{StreamExt, stream::FuturesUnordered};
use sasl::common::{ChannelBinding, Credentials};
use std::{borrow::Cow, collections::BTreeSet, future::Future, sync::Arc, time::Duration};
use tokio::time::{sleep, timeout};
use tokio_xmpp::{
    Stanza,
    connect::{DnsConfig, ServerConnector, StartTlsServerConnector},
    stanzastream::{Connection, Event, StanzaStream, StreamEvent},
    xmlstream::{StreamHeader, Timeouts},
};
use xmpp_parsers::{
    iq::Iq,
    minidom::Element,
    ns,
    presence::{Presence, Type as PresenceType},
    stanza_error::{DefinedCondition, ErrorType, StanzaError},
};

fn backoff(delay: Duration, initial: Duration, maximum: Duration) -> Duration {
    let next = if delay.is_zero() {
        Duration::from_secs(1)
    } else {
        delay.saturating_mul(2)
    };
    next.max(initial).min(maximum)
}

fn negotiated_binding(binding: ChannelBinding, mechanisms: &BTreeSet<String>) -> ChannelBinding {
    // With binding data, sasl selects only the -PLUS names. Servers without
    // -PLUS must still be able to use SCRAM rather than falling back to PLAIN.
    if mechanisms.contains("SCRAM-SHA-256-PLUS") || mechanisms.contains("SCRAM-SHA-1-PLUS") {
        binding
    } else {
        ChannelBinding::Unsupported
    }
}

async fn connect(config: &Config, connector: &StartTlsServerConnector) -> Result<Connection> {
    let jid = config.jid.clone().into();
    // The library probes idle streams with XEP-0198, or XEP-0199 without SM.
    // Its timeout API has no disabled value; a 136-year idle interval disables
    // probing for the lifetime of this process without overflowing Instant.
    let timeouts = if config.ping_interval.is_zero() || config.ping_timeout.is_zero() {
        Timeouts {
            read_timeout: Duration::from_secs(u32::MAX.into()),
            response_timeout: Duration::from_secs(15),
        }
    } else {
        Timeouts {
            read_timeout: config.ping_interval,
            response_timeout: config.ping_timeout,
        }
    };
    let (stream, binding) = connector.connect(&jid, ns::JABBER_CLIENT, timeouts).await?;
    let (features, stream) = stream.recv_features().await?;
    let credentials = Credentials::default()
        .with_username(
            config
                .jid
                .node()
                .context("missing XMPP account name")?
                .as_str(),
        )
        .with_password(config.password.clone())
        .with_channel_binding(negotiated_binding(binding, &features.sasl_mechanisms));
    let stream = tokio_xmpp::client_login(stream, features.sasl_mechanisms, credentials).await?;
    let stream = stream
        .send_header(StreamHeader {
            to: Some(Cow::Borrowed(config.jid.domain().as_str())),
            from: None,
            id: None,
        })
        .await?;
    let (features, stream) = stream.recv_features().await?;
    Ok(Connection {
        stream: stream.box_stream(),
        features,
        identity: jid,
    })
}

fn session(config: &Config, connector: StartTlsServerConnector) -> StanzaStream {
    let config = Arc::new(config.clone());
    let mut first = true;
    // Use the library's stream management, with our existing configurable
    // reconnect policy instead of Client's hard-coded 1..30 second backoff.
    StanzaStream::new(
        Box::new(move |_, mut slot| {
            let config = Arc::clone(&config);
            let connector = connector.clone();
            let initial_connection = first;
            first = false;
            tokio::spawn(async move {
                let attempts = async {
                    let mut delay = config.reconnect_initial;
                    if !initial_connection {
                        sleep(delay).await;
                    }
                    loop {
                        log::info!("connecting to XMPP as {}", config.jid);
                        match timeout(Duration::from_secs(30), connect(&config, &connector)).await {
                            Ok(Ok(connection)) => return connection,
                            Ok(Err(error)) => log::warn!("XMPP connection failed: {error:#}"),
                            Err(_) => log::warn!("XMPP connection timed out"),
                        }
                        log::info!("reconnecting in {}s", delay.as_secs_f64());
                        sleep(delay).await;
                        delay = backoff(delay, config.reconnect_initial, config.reconnect_max);
                    }
                };
                tokio::select! {
                    biased;
                    _ = slot.closed() => {},
                    connection = attempts => { let _ = slot.send(connection); },
                }
            });
        }),
        16,
    )
}

fn iq_reply(
    iq: Iq,
    filters: &protocol::Filters,
) -> Option<(Iq, Option<(String, serde_json::Value)>)> {
    let (from, to, id, payload, set) = match iq {
        Iq::Get {
            from,
            to,
            id,
            payload,
        } => (from, to, id, payload, false),
        Iq::Set {
            from,
            to,
            id,
            payload,
        } => (from, to, id, payload, true),
        _ => return None,
    };
    let mut notification = None;
    let response = if set
        && payload.is("pubsub", ns::PUBSUB)
        && payload.get_child("publish", ns::PUBSUB).is_some()
    {
        notification = protocol::notification(&payload, filters);
        Some(None)
    } else if !set && payload.is("ping", ns::PING) {
        Some(None)
    } else if !set && payload.is("query", ns::DISCO_INFO) && payload.attr("node").is_none() {
        let mut query = Element::builder("query", ns::DISCO_INFO).append(
            Element::builder("identity", ns::DISCO_INFO)
                .attr("category".try_into().unwrap(), "client")
                .attr("type".try_into().unwrap(), "bot")
                .attr("name".try_into().unwrap(), "Gecko push proxy")
                .build(),
        );
        for feature in [ns::DISCO_INFO, ns::DISCO_ITEMS, ns::PING, "urn:xmpp:push:0"] {
            query = query.append(
                Element::builder("feature", ns::DISCO_INFO)
                    .attr("var".try_into().unwrap(), feature)
                    .build(),
            );
        }
        Some(Some(query.build()))
    } else if !set && payload.is("query", ns::DISCO_ITEMS) && payload.attr("node").is_none() {
        Some(Some(Element::builder("query", ns::DISCO_ITEMS).build()))
    } else {
        None
    };
    let reply = match response {
        Some(payload) => Iq::Result {
            from: to,
            to: from,
            id,
            payload,
        },
        None => Iq::Error {
            from: to,
            to: from,
            id,
            payload: Some(payload),
            error: StanzaError::new(
                ErrorType::Cancel,
                DefinedCondition::ServiceUnavailable,
                "en",
                "Unsupported request",
            ),
        },
    };
    Some((reply, notification))
}

pub async fn run(
    config: &Config,
    apns: &Apns,
    stop: impl Future<Output = Result<()>>,
) -> Result<()> {
    let connector =
        StartTlsServerConnector::from(DnsConfig::srv_default_client(config.jid.domain().as_str()));
    serve(config, apns, connector, stop).await
}

async fn serve(
    config: &Config,
    apns: &Apns,
    connector: StartTlsServerConnector,
    stop: impl Future<Output = Result<()>>,
) -> Result<()> {
    let mut stream = session(config, connector);
    let mut filters = protocol::Filters::new();
    let mut pushes = FuturesUnordered::new();
    let result = tokio::select! {
        biased;
        result = stop => result,
        result = async {
        loop {
            tokio::select! {
                biased;
                Some(()) = pushes.next(), if !pushes.is_empty() => {},
                event = stream.next(), if pushes.len() < 64 => {
                    match event.context("XMPP stream terminated")? {
                        Event::Stream(StreamEvent::Reset { bound_jid, .. }) => {
                            if bound_jid != config.jid {
                                bail!("server bound {bound_jid}, expected fixed push address {}", config.jid);
                            }
                            log::info!("connected as {bound_jid}");
                            stream.send(Box::new(Presence::new(PresenceType::None).into())).await;
                        }
                        Event::Stream(StreamEvent::Resumed) => log::info!("XMPP session resumed"),
                        Event::Stream(StreamEvent::Suspended) => log::warn!("XMPP disconnected; reconnecting"),
                        Event::Stanza(Stanza::Message(message)) => {
                            if protocol::update_filters(&message.into(), &mut filters).is_err() {
                                log::warn!("invalid push filters; keeping previous rules");
                            }
                        }
                        Event::Stanza(Stanza::Iq(iq)) => {
                            if let Some((reply, notification)) = iq_reply(iq, &filters) {
                                // Preserve acknowledge-before-APNs semantics. This is not a durable queue.
                                stream.send(Box::new(reply.into())).await;
                                if let Some((token, payload)) = notification {
                                    pushes.push(async move {
                                        match apns.push(&token, &payload).await {
                                            Ok(status) => log::info!("push completed: APNs {status}"),
                                            Err(error) => log::warn!("APNs request failed: {error:#}"),
                                        }
                                    });
                                }
                            }
                        }
                        Event::Stanza(_) => {},
                    }
                }
            }
        }
        } => result,
    };
    // Fit within the deployment's ten-second termination grace period.
    let _ = timeout(Duration::from_secs(2), stream.close()).await;
    if timeout(Duration::from_secs(5), async {
        while pushes.next().await.is_some() {}
    })
    .await
    .is_err()
    {
        log::warn!("shutdown timed out waiting for APNs requests");
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_is_capped_and_zero_can_recover() {
        let initial = Duration::from_millis(250);
        let max = Duration::from_secs(1);
        assert_eq!(backoff(initial, initial, max), Duration::from_millis(500));
        assert_eq!(backoff(max, initial, max), max);
        assert_eq!(backoff(Duration::ZERO, Duration::ZERO, max), max);
    }

    #[test]
    fn scram_selects_only_advertised_channel_binding_modes() {
        use sasl::client::{Mechanism, mechanisms::Scram};
        use sasl::common::scram::Sha256;
        for (offered, expected) in [
            ("SCRAM-SHA-256", "SCRAM-SHA-256"),
            ("SCRAM-SHA-256-PLUS", "SCRAM-SHA-256-PLUS"),
        ] {
            let binding = negotiated_binding(
                ChannelBinding::TlsExporter(vec![42; 32]),
                &BTreeSet::from([offered.to_owned()]),
            );
            let credentials = Credentials::default()
                .with_username("push")
                .with_password("password")
                .with_channel_binding(binding);
            let mechanism = Scram::<Sha256>::from_credentials(credentials).unwrap();
            assert_eq!(mechanism.name(), expected);
        }
    }

    #[test]
    fn iq_responses_route_to_sender_and_reject_unsupported_requests() {
        let parse = |xml: &str| Iq::try_from(xml.parse::<Element>().unwrap()).unwrap();
        let ping = parse(
            "<iq xmlns='jabber:client' from='server.test' to='push@server.test/proxy' id='p' type='get'><ping xmlns='urn:xmpp:ping'/></iq>",
        );
        let (reply, push) = iq_reply(ping, &protocol::Filters::new()).unwrap();
        assert!(push.is_none());
        assert!(
            matches!(&reply, Iq::Result { from: Some(from), to: Some(to), id, payload: None } if from.to_string() == "push@server.test/proxy" && to.to_string() == "server.test" && id == "p")
        );
        let unsupported = parse(
            "<iq xmlns='jabber:client' from='server.test' id='x' type='get'><foo xmlns='urn:unknown'/></iq>",
        );
        assert!(matches!(
            iq_reply(unsupported, &protocol::Filters::new()).unwrap().0,
            Iq::Error {
                error: StanzaError {
                    defined_condition: DefinedCondition::ServiceUnavailable,
                    ..
                },
                ..
            }
        ));
    }
}
