use std::collections::{HashMap, HashSet};

use anyhow::{Result, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use xmpp_parsers::minidom::Element;

const CLIENT: &str = "jabber:client";
const PUBSUB: &str = "http://jabber.org/protocol/pubsub";
const PUSH: &str = "urn:xmpp:push:0";
const DATA: &str = "jabber:x:data";
const SUMMARY: &str = "urn:xmpp:push:summary";

#[derive(Debug, Default, PartialEq, Eq)]
pub struct FilterRules {
    muted: HashSet<String>,
    mention: HashMap<String, String>,
}

pub type Filters = HashMap<String, FilterRules>;

#[derive(Deserialize)]
struct FilterUpdate {
    token: String,
    #[serde(default)]
    muted: Vec<String>,
    #[serde(default)]
    mention_only: Vec<MentionRule>,
}

#[derive(Deserialize)]
struct MentionRule {
    jid: String,
    #[serde(default)]
    nick: String,
}

pub fn valid_token(token: &str) -> bool {
    (32..=200).contains(&token.len()) && token.bytes().all(|byte| byte.is_ascii_hexdigit())
}

pub fn update_filters(message: &Element, filters: &mut Filters) -> Result<()> {
    if !message.is("message", CLIENT) {
        return Ok(());
    }
    let payload = message
        .get_child("filters", "urn:gecko:push:filters")
        .map(Element::text)
        .filter(|text| !text.is_empty())
        .or_else(|| {
            message
                .get_child("body", CLIENT)
                .map(Element::text)
                .filter(|text| text.contains("\"gecko-push-filters\""))
        });
    let Some(payload) = payload else {
        return Ok(());
    };
    let update: FilterUpdate = serde_json::from_str(&payload)?;
    ensure!(
        valid_token(&update.token),
        "invalid APNs device token in filters"
    );
    // Construct the entire replacement before touching the previous rules.
    let rules = FilterRules {
        muted: update
            .muted
            .into_iter()
            .map(|jid| jid.to_lowercase())
            .collect(),
        mention: update
            .mention_only
            .into_iter()
            .map(|entry| (entry.jid.to_lowercase(), entry.nick))
            .collect(),
    };
    filters.insert(update.token.to_ascii_lowercase(), rules);
    Ok(())
}

pub fn notification(pubsub: &Element, filters: &Filters) -> Option<(String, Value)> {
    if !pubsub.is("pubsub", PUBSUB) {
        return None;
    }
    let publish = pubsub.get_child("publish", PUBSUB)?;
    let token = publish.attr("node")?;
    if !valid_token(token) {
        return None;
    }
    let form = publish
        .get_child("item", PUBSUB)?
        .get_child("notification", PUSH)?
        .get_child("x", DATA)?;
    let mut count = 1_i64;
    let mut sender = String::new();
    let mut body = String::new();
    for field in form.children().filter(|field| field.is("field", DATA)) {
        let Some(value) = field.get_child("value", DATA) else {
            continue;
        };
        let text = value.text();
        match field.attr("var") {
            Some("FORM_TYPE") if text != SUMMARY => return None,
            Some("message-count") => {
                if let Ok(parsed) = text.trim().parse::<i64>() {
                    count = parsed;
                }
            }
            Some("last-message-sender") if !text.is_empty() => sender = text,
            Some("last-message-body") if !text.is_empty() => body = text,
            _ => {}
        }
    }
    // Bodiless chat states, receipts and server twins must never wake the user.
    // A bodyful publish is independent: there is deliberately no time-window dedup.
    if body.is_empty() {
        return None;
    }
    let token = token.to_ascii_lowercase();
    let mut show_alert = true;
    if !sender.is_empty()
        && let Some(rules) = filters.get(&token)
    {
        let bare = sender.split('/').next().unwrap_or_default().to_lowercase();
        show_alert = !rules.muted.contains(&bare);
        if let Some(nick) = rules.mention.get(&bare) {
            show_alert &= body.to_lowercase().contains(&nick.to_lowercase());
        }
    }
    let badge = count.max(1);
    let aps = if show_alert {
        json!({
            "alert": {
                "title": "Gecko",
                "body": if badge == 1 { "New message".to_owned() } else { format!("{badge} new messages") }
            },
            "badge": badge,
            "sound": "default",
            "mutable-content": 1,
            "thread-id": "gecko-messages"
        })
    } else {
        json!({"badge": badge})
    };
    Some((token, json!({"aps": aps})))
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: &str = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";

    fn message(payload: &Value) -> Element {
        Element::builder("message", CLIENT)
            .append(
                Element::builder("filters", "urn:gecko:push:filters")
                    .append(payload.to_string())
                    .build(),
            )
            .build()
    }

    fn publish(
        token: &str,
        count: Option<&str>,
        sender: Option<&str>,
        body: Option<&str>,
    ) -> Element {
        let mut form = Element::builder("x", DATA)
            .attr("type".try_into().unwrap(), "submit")
            .build();
        for (var, value) in [
            ("FORM_TYPE", Some(SUMMARY)),
            ("message-count", count),
            ("last-message-sender", sender),
            ("last-message-body", body),
        ] {
            if let Some(value) = value {
                form.append_child(
                    Element::builder("field", DATA)
                        .attr("var".try_into().unwrap(), var)
                        .append(Element::builder("value", DATA).append(value).build())
                        .build(),
                );
            }
        }
        Element::builder("pubsub", PUBSUB)
            .append(
                Element::builder("publish", PUBSUB)
                    .attr("node".try_into().unwrap(), token)
                    .append(
                        Element::builder("item", PUBSUB)
                            .append(Element::builder("notification", PUSH).append(form).build())
                            .build(),
                    )
                    .build(),
            )
            .build()
    }

    #[test]
    fn token_boundaries_are_ascii_hex_only() {
        for length in [32, 64, 200] {
            assert!(valid_token(&"aB09".repeat(50)[..length]));
        }
        for token in [
            "a".repeat(31),
            "a".repeat(201),
            "g".repeat(64),
            "é".repeat(32),
            format!("{TOKEN}\n"),
        ] {
            assert!(!valid_token(&token));
            assert!(
                notification(&publish(&token, None, None, Some("hi")), &Filters::new()).is_none()
            );
        }
    }

    #[test]
    fn filters_normalize_replace_and_reject_invalid_updates_atomically() {
        let mut filters = Filters::new();
        update_filters(
            &message(&json!({"token": TOKEN.to_uppercase(),
            "muted": ["Alice@Example.com"],
            "mention_only": [{"jid": "Room@MUC", "nick": "Rachel"}]})),
            &mut filters,
        )
        .unwrap();
        assert!(filters[TOKEN].muted.contains("alice@example.com"));
        assert_eq!(filters[TOKEN].mention["room@muc"], "Rachel");
        for payload in [
            json!({"token": TOKEN, "muted": [42]}),
            json!({"token": TOKEN, "muted": null}),
            json!({"token": TOKEN, "mention_only": [{"jid": "room@muc", "nick": false}]}),
            json!({"token": TOKEN, "mention_only": [{}]}),
            json!({"token": "invalid"}),
            json!({"token": 42}),
            json!([]),
        ] {
            assert!(update_filters(&message(&payload), &mut filters).is_err());
            assert!(filters[TOKEN].muted.contains("alice@example.com"));
            assert_eq!(filters[TOKEN].mention["room@muc"], "Rachel");
        }
        let malformed: Element = "<message xmlns='jabber:client'><filters xmlns='urn:gecko:push:filters'>{bad</filters></message>".parse().unwrap();
        assert!(update_filters(&malformed, &mut filters).is_err());
        assert!(filters[TOKEN].muted.contains("alice@example.com"));
        update_filters(&message(&json!({"token": TOKEN})), &mut filters).unwrap();
        assert_eq!(filters[TOKEN], FilterRules::default());
    }

    #[test]
    fn legacy_body_is_recognized_but_unrelated_messages_are_ignored() {
        let mut filters = Filters::new();
        for xml in [
            "<message xmlns='jabber:client'><body>normal chat</body></message>".to_owned(),
            format!(
                "<message xmlns='jabber:client'><body>{{\"token\":\"{TOKEN}\"}}</body></message>"
            ),
            "<message xmlns='jabber:client'><filters xmlns='unrelated'>{broken</filters></message>"
                .to_owned(),
        ] {
            update_filters(&xml.parse().unwrap(), &mut filters).unwrap();
            assert!(filters.is_empty());
        }
        let xml = format!(
            "<message xmlns='jabber:client'><body>{{\"type\":\"gecko-push-filters\",\"token\":\"{TOKEN}\",\"mention_only\":[{{\"jid\":\"Room@MUC\"}}]}}</body></message>"
        );
        update_filters(&xml.parse().unwrap(), &mut filters).unwrap();
        assert_eq!(filters[TOKEN].mention["room@muc"], "");
    }

    #[test]
    fn summaries_produce_exact_generic_payloads_without_private_content() {
        for (count, badge, banner) in [
            (None, 1, "New message"),
            (Some("bad"), 1, "New message"),
            (Some("0"), 1, "New message"),
            (Some("-4"), 1, "New message"),
            (Some("1"), 1, "New message"),
            (Some("3"), 3, "3 new messages"),
        ] {
            let (token, payload) = notification(
                &publish(
                    &TOKEN.to_uppercase(),
                    count,
                    Some("private@example.com/phone"),
                    Some("private message"),
                ),
                &Filters::new(),
            )
            .unwrap();
            assert_eq!(token, TOKEN);
            assert_eq!(
                payload,
                json!({"aps": {"alert": {"title": "Gecko", "body": banner},
                "badge": badge, "sound": "default", "mutable-content": 1, "thread-id": "gecko-messages"}})
            );
        }
    }

    #[test]
    fn bodyless_twins_drop_and_each_bodyful_publish_delivers() {
        let filters = Filters::new();
        let inputs = [
            publish(TOKEN, Some("1"), None, None),
            publish(TOKEN, Some("1"), None, Some("")),
            publish(
                TOKEN,
                Some("1"),
                None,
                Some("[This message is OMEMO encrypted]"),
            ),
            publish(TOKEN, Some("1"), None, Some("second")),
            publish(&"bb".repeat(32), Some("1"), None, Some("second")),
        ];
        let notifications: Vec<_> = inputs
            .iter()
            .filter_map(|input| notification(input, &filters))
            .collect();
        assert_eq!(notifications.len(), 3);
        assert_eq!(notifications[0].0, TOKEN);
        assert_eq!(notifications[1].0, TOKEN);
        assert_eq!(notifications[2].0, "bb".repeat(32));
    }

    #[test]
    fn mute_and_mention_rules_only_suppress_alerts() {
        let mut filters = Filters::new();
        update_filters(&message(&json!({"token": TOKEN, "muted": ["Alice@Example.com", "muted@muc"],
            "mention_only": [{"jid": "Room@MUC", "nick": "Rachel"}, {"jid": "muted@muc", "nick": "Rachel"},
                {"jid": "empty@muc"}]})), &mut filters).unwrap();
        for (sender, body, alert) in [
            ("ALICE@example.com/Phone", "hi", false),
            ("bob@example.com/x", "hi", true),
            ("room@muc/someone", "hello everyone", false),
            ("ROOM@muc/someone", "hey RACHEL!", true),
            ("muted@muc/someone", "Rachel!", false),
            ("empty@muc/someone", "anything", true),
        ] {
            let (_, payload) = notification(
                &publish(TOKEN, Some("3"), Some(sender), Some(body)),
                &filters,
            )
            .unwrap();
            assert_eq!(payload["aps"].get("alert").is_some(), alert);
            if !alert {
                assert_eq!(payload, json!({"aps": {"badge": 3}}));
            }
        }
        assert!(
            notification(
                &publish(TOKEN, Some("1"), Some("room@muc/x"), None),
                &filters
            )
            .is_none()
        );
        assert!(
            notification(&publish(TOKEN, None, None, Some("hi")), &filters)
                .unwrap()
                .1["aps"]
                .get("alert")
                .is_some()
        );
    }

    #[test]
    fn only_push_summary_namespace_paths_are_used() {
        let xml = format!(
            "<pubsub xmlns='{PUBSUB}'><publish node='{TOKEN}'><item><notification xmlns='{PUSH}'><x xmlns='{DATA}'><field var='FORM_TYPE'><value>{SUMMARY}</value></field><field var='last-message-body'><value>hello &amp; goodbye</value></field></x></notification></item></publish><publish-options><x xmlns='{DATA}'><field var='message-count'><value>999</value></field></x></publish-options></pubsub>"
        );
        assert_eq!(
            notification(&xml.parse().unwrap(), &Filters::new())
                .unwrap()
                .1["aps"]["badge"],
            1
        );
        for bad in [
            xml.replace(PUSH, "urn:unrelated"),
            xml.replace(SUMMARY, "urn:unrelated"),
            xml.replace("var='last-message-body'", "var='unrelated'"),
            xml.replace(
                "<field var='last-message-body'>",
                "<field xmlns='urn:unrelated' var='last-message-body'>",
            ),
            xml.replace("<value>hello", "<value xmlns='urn:unrelated'>hello"),
        ] {
            assert!(notification(&bad.parse().unwrap(), &Filters::new()).is_none());
        }
    }
}
