# Replacing the Dino/Vala core with Swift

Status (November 2026): **complete**. Gecko runs on the Swift core alone and
the Vala tree is deleted (phase 9, below). The history: phase 0 done (`ios/live-test`, all seven steps pass
on the Vala core); phase 1 core written in `GeckoKit/Sources/GeckoKit/XMPP/` and
logging in to xmpp.is (direct TLS and STARTTLS, SCRAM, bind, stream management
with resumption after a dropped connection), not yet wired into the app;
phase 2's store (GRDB) and importer done: a copy of a real Dino database
imports with every count matching. Phase 3 under way: with
`DINO_SWIFT_CORE=1` the app runs on the Swift core (`SwiftCore`, behind
`GeckoCore`), importing the Vala data on first launch and keeping passwords in
the Keychain; accounts, contacts and requests, presence, the chat list and
one-to-one plain messages pass the live script, and so do read markers,
reactions, replies, corrections, typing, server-history catch-up and copies of
what our other devices send, avatars (PEP, then vCard), blocking, presence
status, nickname, account details and password change (`run.sh --core swift
reset contact-request plain-messages message-extras other-devices profile
status remove-contact`). The `status` step also exposes a Vala bug the Swift
core does not have: the Vala core's presence carried an empty `<show/>` and
`<status/>`, so a chosen status never reached anyone.

Phase 4 under way: OMEMO in the Swift core through libomemo-c
(`OMEMOSession`, store callbacks on `GeckoStore`, crypto from CryptoKit and
CommonCrypto), the XEP-0384 stanzas (`OMEMOStanzas`) and the per-account
`OMEMOCoordinator` (our device list and bundle, contacts' devices, sessions
from bundles, blind trust before verification, repair of a session that stops
decrypting). The keys imported from a real Dino database open as the same
device with the same identity, and an imported session with the live script's
peer carried on without a new pre-key exchange; `omemo-messages` passes against
python-omemo. Both cores share an account's OMEMO device but not its sessions,
so testing them alternately desynchronises the sessions: `run.sh --core swift
--reimport` takes the Vala core's current state first.

Phase 5 under way: group chats in the Swift core (`MUC`, `RoomCoordinator`):
joining from XEP-0402 bookmarks and open room conversations, occupants with
offline members of private rooms, room messages both ways with our own
reflections deduplicated, subjects and room information, room history from the
room's archive, invitations (mediated and direct) both ways, private messages to
members, removal (kick, ban, members-only), creating rooms (instant), owner
settings (name, private, moderated, picture), moderation (kick, role,
affiliation), and OMEMO in private rooms. Live steps `group-chat`,
`room-omemo` and `room-admin` pass on the Swift core.

Phase 6 under way: files through the server's HTTP upload service
(`FileSharing`, `FileTransfers`). The size limit is checked before sending;
uploads report progress, retry the PUT three times, and wait out a dropped
connection to resume once the account is back. OMEMO chats and private rooms
send AES-256-GCM files as `aesgcm://` links. Incoming messages that only share a
file become file items (images are fetched at once); downloads report progress,
check the GCM tag, and can be retried. Jingle file offers are refused
(`service-unavailable`; the feature is not advertised). Downloads stream into a
partial file and resume where they stopped (HTTP ranges; a server that ignores
the range starts the file over), and the progress row cancels an upload (it is
not sent) or a download (what arrived is kept). Still open: uploads, and the
decryption of an encrypted download, hold the whole file in memory. Live steps
`files` and `omemo-files` pass on the Swift core.

Phase 7 under way: push registration (XEP-0357: every earlier registration
with the service is dropped, then one is made) and the proxy's filter message,
re-sent when a notification setting changes. The notification extension uses
the Swift core when the app does (the app records its core in the App Group
defaults): a short session without stream management, presence or room joins
catches up on the account's and the open rooms' archives, storing and
decrypting into the shared database (no OMEMO repair, no key publishing), and
reports the incoming messages and the unread total. Passwords live in the App
Group keychain so the extension can sign in, and the store waits on the other
process's lock. Live steps `push-register` and `push-fetch` pass on the Swift
core. Still open: OMEMO messages in rooms (the extension knows no members'
real JIDs without joining), and device checks of the 24 MB / 30 s budget.

Phase 8 under way: `CallSignaling` talks to the Swift core. It advertises the
call features, hands over one-to-one Jingle Message Initiation messages (live
and our other devices' carbons, never room or archive copies) and the Jingle
requests of call sessions (tracked by sid from the RTP offer to the hang-up),
and sends CallSignaling's stanzas, returning the answers to its requests as
`stanza` events, exactly as the bridge did. Every command now reaches the
Swift core; `notInSwiftCore` is gone. Live step `call-signalling` (the peer as
callee: proposal, proceed, offer, hang-up) passes on both cores; media between
two devices is still to be checked on hardware.

Phase 9 done (November 2026), sooner than planned: rather than keep Vala for
one release, the Vala trees (`libdino`, `xmpp-vala`, `qlite`, `crypto-vala`,
`plugins`), the C bridge `ios/bridge`, Meson, `build-core.sh` and the GLib,
libsoup, gcrypt and OpenSSL builds were deleted; `build-deps.sh` builds only
protobuf-c, libomemo-c and GRDB and fetches WebRTC. `GeckoCore` talks to
`SwiftCore` alone, and `DinoImport` still brings a Dino-based install's data
across on first launch. The whole live script passes on the Vala-free build.
Encrypted chats refuse to send rather than send in the clear.

## Decisions

- **Our own Swift connection core** on Network.framework, written from the
  XMPP RFCs and XEPs. No Martin (AGPL-3.0) and no XMPPFramework (permissive, but
  last pushed April 2024).
- **OMEMO stays on `libomemo-c`** (GPL-3.0, C, already cross-compiled) behind a
  thin Swift wrapper. This is Monal's model: our new code can carry a permissive
  licence, while the shipped app remains GPL-3.0 because it links `libomemo-c`.
  A permissive OMEMO of our own stays possible later as a separate project.
- **New code, not translation.** The Swift core is written from specifications.
  Porting Vala line by line would make it a derivative of Dino and keep it GPL.
- **The seam is the existing command/event boundary**: the ~60 commands in
  `GeckoCore.swift` and the ~35 JSON event types `AppModel` decodes. The UI does
  not change. A build flag selects the backend until the switch-over.
- **One backend per account at a time.** Both stacks cannot share a connection,
  so the Swift backend is developed against the test accounts while the Vala
  build stays in daily use.
- **Files go through the server only** (XEP-0363); Jingle file transfer is not
  carried over.
- **`oss` branch** (June 2026, XMPPFramework + GRDB): reuse its GRDB store,
  models and tests where they fit; not its XMPPFramework adapter.

## Phases

Each phase ends with a check that has to pass before the next starts.

0. **Contract tests.** The commands and events as tests, plus a live
   two-account script (add contact, accept, message, OMEMO message, group chat,
   file, remove). *Check:* green on the Vala backend.
1. **Connection core.** TLS (STARTTLS and direct), SRV lookup, SCRAM, resource
   binding, stream management (XEP-0198), CSI, ping, reconnect. *Check:* stays
   connected to xmpp.is across network changes and backgrounding; unit tests
   replay recorded server traffic.
2. **Storage and import.** GRDB store and a one-time importer from `dino.db`
   (accounts, messages, files, roster, settings, OMEMO keys and sessions);
   `dino.db` is left in place as a backup. *Check:* a copy of a real database
   imports with matching counts.
3. **Messaging.** 1:1, carbons, MAM, receipts and markers, chat states,
   corrections, replies, reactions, roster and subscriptions, presence,
   avatars, blocking. *Check:* phase-0 tests green on both backends.
4. **OMEMO** via `libomemo-c`, keeping the imported identity and sessions.
   *Check:* Conversations and Dino contacts keep decrypting, with no new-device
   prompt and no trust reset.
5. **Group chats.** Join, occupants, affiliations and roles, configuration,
   invitations, bookmarks, private messages.
6. **Files: server upload only.** HTTP upload (XEP-0363) and OMEMO-encrypted
   files (`aesgcm://`), done properly: upload progress, cancel, retry after a
   failure or a dropped connection, the server's size limit shown before
   sending, and downloads that resume and verify. Direct device-to-device
   transfer (Jingle file transfer, XEP-0234 with SOCKS5/IBB) is dropped: it
   needs both devices online and a working direct or proxy path, and is not
   reliable enough to keep. Incoming Jingle file offers are declined. *Check:*
   sending to and receiving from Conversations and Dino, plain and encrypted,
   including a large file over a flaky network.
7. **Push and the notification extension.** XEP-0357 registration; the NSE's
   fetch and decrypt move off `dino_ios_nse_fetch`.
8. **Calls.** `CallSignaling` talks to the Swift core instead of the
   raw-stanza bridge.
9. **Switch-over.** The Swift backend becomes the default with Vala kept for one
   release, then the Vala trees, the bridge, meson and the GLib dependency stack
   are deleted (only WebRTC and `libomemo-c` remain in `build-deps.sh`), and
   `PORTING.md`, `AGENTS.md` and `README.md` are rewritten.

Phases 2 and 4 carry the most risk: losing history or the OMEMO identity costs
users more than any missing feature, so both are exercised on a copy of real
data before anyone else runs them.
