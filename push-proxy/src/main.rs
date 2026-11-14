mod apns;
mod protocol;
mod xmpp;

use anyhow::{Context, Result, ensure};
use std::{env, time::Duration};
use xmpp_parsers::jid::FullJid;

#[derive(Clone)]
struct Config {
    jid: FullJid,
    password: String,
    ping_interval: Duration,
    ping_timeout: Duration,
    reconnect_initial: Duration,
    reconnect_max: Duration,
}

fn required(name: &str) -> Result<String> {
    let value = env::var(name).with_context(|| format!("missing {name}"))?;
    ensure!(!value.is_empty(), "{name} must not be empty");
    Ok(value)
}

fn seconds(name: &str, default: f64) -> Result<Duration> {
    let value = match env::var(name) {
        Ok(raw) => raw
            .parse::<f64>()
            .with_context(|| format!("{name} must be a number"))?,
        Err(env::VarError::NotPresent) => default,
        Err(e) => return Err(e).with_context(|| format!("invalid {name}")),
    };
    ensure!(value.is_finite(), "{name} must be finite");
    Duration::try_from_secs_f64(value.max(0.0)).with_context(|| format!("{name} is too large"))
}

impl Config {
    fn from_env() -> Result<Self> {
        let jid: FullJid = required("XMPP_JID")?
            .parse()
            .context("XMPP_JID must be a full JID with a fixed resource (user@host/proxy)")?;
        ensure!(
            jid.node().is_some(),
            "XMPP_JID must include an account name"
        );
        let reconnect_initial = seconds("XMPP_RECONNECT_INITIAL", 1.0)?;
        Ok(Self {
            jid,
            password: required("XMPP_PASSWORD")?,
            ping_interval: seconds("XMPP_PING_INTERVAL", 60.0)?,
            ping_timeout: seconds("XMPP_PING_TIMEOUT", 15.0)?,
            reconnect_initial,
            reconnect_max: seconds("XMPP_RECONNECT_MAX", 60.0)?.max(reconnect_initial),
        })
    }
}

async fn shutdown() -> Result<()> {
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        tokio::select! {
            result = tokio::signal::ctrl_c() => result?,
            _ = term.recv() => {},
        }
    }
    #[cfg(not(unix))]
    tokio::signal::ctrl_c().await?;
    log::info!("shutting down");
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    tokio_xmpp::rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| anyhow::anyhow!("TLS provider already configured"))?;
    let config = Config::from_env()?;
    let apns = apns::Apns::new(
        &required("APNS_KEY_PATH")?,
        required("APNS_KEY_ID")?,
        required("APNS_TEAM_ID")?,
        env::var("APNS_TOPIC").unwrap_or_else(|_| "me.anemoneya.gecko".into()),
        env::var("APNS_SANDBOX").map_or(true, |s| s == "1"),
    )?;
    xmpp::run(&config, &apns, shutdown()).await
}
