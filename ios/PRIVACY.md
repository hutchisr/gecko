# Gecko Privacy Policy

_Last updated: 14 June 2026_

Gecko is an XMPP (Jabber) chat client for iPhone. This policy explains what data
Gecko handles and how. The short version: Gecko is built to keep your
conversations private. Your data stays on your device and on the XMPP server you
choose, and the developer does not collect, track, sell, or profile you.

## How Gecko works

Gecko connects to an XMPP server of your choice — the account you sign in with.
The developer of Gecko does **not** operate that server and does not host your
account or your messages. Your messages, contacts, and account data live on your
device and on your chosen server, governed by that server operator's own privacy
policy.

## End-to-end encryption

Gecko supports OMEMO end-to-end encryption. When a conversation is encrypted with
OMEMO, message contents can be read only by you and the people you are messaging —
not by your server, not by the developer, and not by Apple. Messages that are not
end-to-end encrypted (for example, in a public group that doesn't support it) are
handled by your XMPP server like any other XMPP message.

## Data stored on your device

Gecko stores your account settings, message history, contacts, and encryption
keys locally on your device, in the app's private storage. This data leaves your
device only to communicate with your chosen XMPP server. Deleting the app removes
this local data.

## Account credentials

Your XMPP username and password are stored on your device and sent only to your
chosen XMPP server to log in. They are never sent to the developer or any third
party.

## Push notifications

To alert you to new messages while the app is closed, Gecko uses a small push
relay together with Apple's Push Notification service (APNs):

- When a message is waiting, your XMPP server notifies the relay (operated by the
  developer) using your app's Apple-issued device token.
- The relay forwards a notification through Apple, which delivers it to your
  device.
- The relay does **not** receive your message contents. Encrypted messages are
  decrypted only on your device, after the notification arrives. The relay
  processes only your device token and the fact that a message is waiting, and
  does not persist this information.
- Apple's handling of push notifications is governed by Apple's privacy policy.

You can turn notifications off in iOS Settings; messaging still works without
them.

## Voice calls

Gecko uses the microphone only during a call you place or answer, and does not
record calls. Call audio travels between your device and the other person's,
encrypted with DTLS-SRTP. The keys' fingerprints are exchanged through the XMPP
servers and are not yet verified with OMEMO, so calls do not have the same
protection against a malicious server as OMEMO messages.

To connect a call, each side learns the other's IP address. Gecko asks your XMPP
server for STUN/TURN servers to help with that; if your server offers none, it
uses the Dino project's public STUN server (`stun.dino.im`), which sees your IP
address but none of the call. Some servers' relays do not prove who they are;
Gecko still uses them, so someone able to intercept your connection to the relay
could reroute or interrupt a relayed call, but not listen to it.

## Analytics and tracking

Gecko contains no analytics, no advertising, and no third-party tracking SDKs.
The developer collects no usage data and builds no profile of you.

## Data the developer collects

None, beyond the transient push-relay handling described above. There is no
account with the developer, and no personal data is collected, stored, or sold.

## Third parties

- **Your chosen XMPP server operator** — selected by you; subject to their own
  policy.
- **Apple** — for push notification delivery (APNs).
- **The Dino project's STUN server** — only when you place or answer a call and
  your XMPP server offers no STUN/TURN service.

## Children

Gecko is not directed at children under 13.

## Changes

This policy may be updated from time to time; the "last updated" date above will
change to reflect any revisions.

## Contact

Questions about this policy: `<your-contact-email>`
