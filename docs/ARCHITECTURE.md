# Gecko on Apple platforms

Gecko is a SwiftUI XMPP client for iOS and Apple Silicon Macs (Mac Catalyst).
It began as a port of Dino's Vala core with a SwiftUI front end; that core has
been replaced by a native Swift one (`docs/MIGRATION.md` has the history), and
the Vala tree, the C bridge, Meson and the GLib stack are gone. The only C
libraries left are libomemo-c (with protobuf-c) for OMEMO; the store uses GRDB
and calls the prebuilt WebRTC framework.

## Status: what works today

Verified against real servers (xmpp.is) with the live two-account script
(`tools/live-test`, all steps passing in the Simulator) and on Mac Catalyst:

* Accounts: login (direct TLS or STARTTLS, SCRAM), stream management with
  resumption after a dropped connection, password change, sign out.
* Contacts, subscription requests, presence and status, blocking, avatars.
* One-to-one chats with read markers, typing, reactions, replies, corrections,
  server-history catch-up and our other devices' copies.
* **OMEMO** (legacy `eu.siacs.conversations.axolotl`) through libomemo-c, in
  chats and private rooms, with session repair.
* Group chats: bookmarks, joining, occupants, invitations, moderation, room
  settings, room history.
* Files over HTTP upload (plain and `aesgcm://` encrypted), with progress,
  cancel, retries and resumable downloads. Jingle file offers are refused.
* **Push**: XEP-0357 through `push-proxy`, and a notification extension
  that fetches, decrypts and stores what arrived.
* One-to-one voice calls while the app is open.
* First launch after a Dino-based build imports `dino.db` and `omemo.db`
  (history, keys, trust, passwords) into the Swift store (`DinoImport`).

Not done: video and group calls, ringing while closed (CallKit, VoIP push),
OpenPGP, OMEMO 2, and device checks of the notification extension's
24 MB / 30 s budget.

## Layout

| Path | Purpose |
| --- | --- |
| `App/` | The SwiftUI app shared by iOS and Mac Catalyst: views, `AppModel` (`Model.swift`), and `GeckoCore`, which hands the app's commands to `SwiftCore` and its events back to `AppModel`. Also its Info plists, entitlements, assets and icon. |
| `NotificationService/` | The notification service extension: runs `SwiftCore` in its notification mode. |
| `GeckoKit/` | SwiftPM package compiled into both targets and unit-tested on the host. `Sources/GeckoKit/XMPP/` is the XMPP core: transport and negotiation (`XMPPTransport`, `XMPPNegotiation`, `SCRAM`, `StreamManagement`, `XMPPClient`), the store (`GeckoStore`, `StoreQueries`, `DinoImport`), and `SwiftCore` with `RoomCoordinator`, `OMEMOCoordinator`, `Avatars`, `FileSharing`/`FileTransfers`. `Sources/COMEMO` wraps libomemo-c. |
| `UITests/` | XCUITest target (`GeckoUITests`). |
| `Config/` | The xcconfigs the targets build with. |
| `Gecko.xcodeproj` | Builds the app and the extension against `build/prefix/<target>`. |
| `scripts/` | `build-deps.sh` builds what the app links into `build/prefix/<target>`: protobuf-c and libomemo-c (static), GRDB compiled from source into `lib/libGRDB.a` with a textual module interface in `lib/swift` (keep `GRDB_VER` equal to `GeckoKit/Package.swift`), and the prebuilt WebRTC xcframework's slice as `Frameworks/WebRTC.framework`. `build-app.sh` builds `build/app-<target>/Gecko.app` with direct `swiftc` builds on iOS and the Xcode Catalyst driver on macOS, and either way links, embeds and ad-hoc signs `WebRTC.framework` in the app only. `deploy-phone.sh` and `deploy-testflight.sh` re-sign it with the deployment identity before the extension and app. |
| `tools/live-test/` | The live two-account script (below). |
| `push-proxy/` | The XEP-0357 → APNs push proxy (Rust, MIT). |
| `docs/` | This file, the migration history, the privacy policy and release notes. |
| `build/` | Gitignored output: `prefix/<target>`, `deps/` sources, `app-<target>/`. |

## Reproduce

For the iOS Simulator:

```sh
scripts/build-deps.sh sim-arm64
scripts/build-app.sh run sim-arm64
```

For an Apple Silicon Mac:

```sh
scripts/build-deps.sh catalyst-arm64
scripts/build-app.sh run catalyst-arm64
```

Or open `Gecko.xcodeproj` in Xcode and build the shared `Gecko` scheme. The
scheme selects `build/prefix/sim-arm64`, `build/prefix/device-arm64`, or
`build/prefix/catalyst-arm64` from the destination SDK.

TestFlight packaging supports both device iOS and Mac Catalyst through
`scripts/deploy-testflight.sh [device-arm64|catalyst-arm64]`; iOS remains the
default. The Mac path archives this same scheme and uses Xcode-managed App Store
distribution signing to export a `.pkg`, without the iOS-only NSE. See
[`TESTFLIGHT.md`](TESTFLIGHT.md) for platform setup and upload commands.

Both app targets require OS 26 and use the system's Liquid Glass toolbar and
sheet treatments. Keep toolbar actions as native `ToolbarItem` /
`ToolbarItemGroup` controls rather than fixed-size stacks with custom hover
backgrounds or stacked glass treatments. Chat's trailing actions use the
labeled `ToolbarItemGroup` initializer, which wraps them in a native
`ControlGroup` so they share one glass background on Catalyst as well as iOS.
The label describes the group if it collapses into a menu when space is tight.
The custom chat composer groups its
field, controls, and accessory banners in one `GlassEffectContainer`; its
6-point spacing is the glass merging threshold, not the layout gap. Message
bubbles and attachment thumbnails remain content surfaces, not glass.
Catalyst retains its native Contacts search field, Escape shortcuts, and media
window close controls; the media viewer keeps its immersive black backdrop.
A fixed `ToolbarSpacer` separates Contacts' Add action from its search field
into distinct glass backgrounds.
Catalyst's standalone sheet Close and Add buttons use `.buttonStyle(.glass)`
with the toolbar's shared background hidden, so the visible circle is the
interactive control rather than a larger decorative toolbar background.
Four-point label padding restores the roughly 36-point toolbar height.
Account settings and Room details are panes, not sheets: each is pushed with
`navigationDestination(isPresented:)`, onto the one stack on iOS and onto the
stack in the split view's detail column on Catalyst, so the chat underneath
keeps its draft. Escape goes back (`escapeGoesBack()`), and opening a
conversation leaves Settings.
The Catalyst Account toolbar item uses a native `UIButton` with live SwiftUI
artwork via `UIHostingConfiguration`: toolbar label extraction otherwise reduces
the avatar to its initial or drops asynchronously loaded artwork and the status
dot. The native button owns hit testing, while `CachedDiskImage` updates the
artwork by path without replacing the control. The account-avatar
fixture's `DINO_UI_TEST_AVATAR_UPDATE=1` checks a pink-to-cyan image change;
the Catalyst interaction regression checks chat switching and Account dismissal.

A picked account or room photo goes through `AvatarCropView` before it is
published: the image fills a square (shown with the round mask avatars get),
the user drags to move it and pinches or uses the slider to zoom up to 5×, and
"Use Photo" writes that square as a PNG of at most 512px. The geometry is the
pure `AvatarCrop` in GeckoKit, covered by `AvatarCropTests`.

Mac Catalyst uses a persistent desktop lifecycle: it keeps XMPP connected when
the window is hidden and identifies as a desktop client, and posts local
notifications only while it is not frontmost (set at launch too). "Frontmost"
comes from AppKit's activation notifications (`CatalystWindowLifecycle.isActive`):
on Catalyst SwiftUI's `scenePhase` and `UIApplication.applicationState` stay
active when another app comes forward. The same signal blurs the open chat,
so messages count as unread until the window is back in front. iOS closes
its streams cleanly 3 s after going to the background (inside a background
task) and reconnects on return: with no session held, messages wait in offline
storage and the archive and push as usual, while copies of what we send from
other devices do not wake the phone. Messages that arrive through archive
catch-up are marked `synced` and do not notify.
The Mac close button orders the underlying window out instead of destroying its
`UIWindowScene`, so the process and XMPP connection remain alive; Dock
activation orders that same window back in front. Catalyst exposes no public
UIKit close-veto callback, so this local build forwards the underlying AppKit
window/application delegates through runtime proxies. Revisit that unsupported
interop before a Mac App Store submission.
The reopen path observes native macOS application activation because an
ordered-out UIKit scene may not emit another activation callback. It also
observes replacement of the native application and primary-window delegates,
reinstalling the proxies immediately: waiting for activation misses Dock clicks
when Gecko is already active, and losing the window proxy makes later closes
destroy the scene instead of hiding it. Media-window delegates remain untouched.
The hidden-window reference is cleared only after the window reports itself
visible; a failed ordering attempt gets one deferred retry and retains the
window for subsequent reopen requests.

Three focused Catalyst UI checks passed on 2026-11-10: close/Dock reopen,
application Hide/reactivation, and repeated close/reopen after replacing both
delegates without first activating Finder. They verify preserved drafts,
keyboard input, and a single chat window. This covers delegate-replacement
recovery, not a reproduction or conclusive diagnosis of the long-idle failure.

The app supports headless automation for testing via environment variables
(set through `SIMCTL_CHILD_*`): `DINO_AUTOLOGIN=jid:password`,
`DINO_AUTOPEER=jid` (opens a chat), `DINO_AUTOSEND=text` (`DINO_AUTOSENDDELAY=s`: when),
`DINO_AUTOSENDFILE=1` (generated PNG) or `DINO_AUTOSENDFILE=svg`,
`DINO_AUTOOMEMO=1` (enable encryption before sending; `0` turns it off),
`DINO_AUTOACCEPT=jid` (accept that contact's request when it arrives),
`DINO_AUTOREMOVECONTACT=jid`, `DINO_AUTOBLOCK=jid`, `DINO_AUTOUNBLOCK=jid`,
`DINO_AUTOBLOCKLIST=1`, `DINO_AUTOSTATUS=show:text`,
`DINO_AUTOCHANGEPASSWORD=password`, `DINO_AUTOROOMSEND=text` with
`DINO_AUTOJOINMUC` (and `DINO_AUTOROOMOMEMO=1`), `DINO_AUTOJOININVITE=1`,
`DINO_AUTOCREATEMUC=jid` with `DINO_AUTOROOMNAME=name` and
`DINO_AUTOROOMKICK=nick`, `DINO_AUTOPUSH=jid` (register for push with that
service, token `live-test-token`), `DINO_LIVE_TEST=1` (one `gecko-live:` JSON line
per message, request, roster, room-member and error event), and
`DINO_LOG_XMPP=all` (stanza log on stderr, visible via
`simctl launch --console-pty`).

`tools/live-test/run.sh` checks Gecko end to end against xmpp.is with two
accounts: Gecko in the booted Simulator, signed in as `USERNAME` from
`credentials.local.txt`, and a Python client (slixmpp, slixmpp-omemo) signed
in as `USERNAME2`/`PASSWORD2` playing the other person. Steps: `reset`,
`contact-request`, `plain-messages`, `files`, `omemo-files` (encrypted
`aesgcm://` files both ways), `push-register` (Gecko registers with a push
service, played by the peer, and sends it its filters; a second login then
drops that registration; needs `contact-request` first, as xmpp.is drops
bodyless messages between strangers), `push-fetch` (a `simctl push` while Gecko is closed:
the notification extension stores and decrypts what arrived, checked in the
store, then shown once by the app), `call-signalling` (Gecko calls the peer, which
answers the proposal, takes the Jingle offer and hangs up; signalling only, no
media; needs `contact-request` first), `message-extras` (read markers,
reactions, replies, corrections and typing, both ways), `other-devices` (what
arrived while Gecko was closed, and a message from a second geckotest login),
`profile` (the peer's avatar, blocking, a password change to the same password),
`status` (Gecko's away status reaching the peer), `omemo-messages`, `group-chat` (members,
messages both ways, accepting an invitation), `room-omemo` (OMEMO in a private
room, both ways), `room-admin` (Gecko creates a room, renames it, removes a
member),
`remove-contact` (all by default, or name some).
`--log` keeps each launch's console with the stanza log in `.state/`.
Run one at a time: two runs, or anything else launching Gecko meanwhile, share the
Simulator and spoil each other. With several Simulators booted, `simctl …
booted` means any one of them; the script then refuses to start until
`GECKO_SIM_DEVICE=<udid>` names one, and manual `simctl` commands should name
the device too. It reads Gecko's side from
the `gecko-live:` lines, which come from `AppModel`. Needs `uv`; install a current build
first (`build-app.sh build sim-arm64` then `simctl install booted`). The peer's
OMEMO keys persist in `tools/live-test/.state/` so it stays one device.

Chat UI regressions run without an account using the in-memory fixtures in
`Model.swift`:

```sh
xcodebuild test -project Gecko.xcodeproj -scheme Gecko \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GeckoUITests/ChatVisibilityUITests
```

Incoming room invitations appear above the active chat with Join/Ignore actions;
failed joins retain the invitation and offer Retry before advancing the queue.
The `DINO_UI_TEST_MUC_INVITES=1` chat fixture queues two invitations;
`DINO_UI_TEST_MUC_INVITE_FAILURE=1` fails the first join once. The three room
invitation cases in `ChatVisibilityUITests` exercise ignore, join, and retry
without starting the core or accessing an account.

`testRoomDetailsSeparatesOnlineAndOfflineMembers` uses
`DINO_UI_TEST_ROOM_MEMBERS=1` with that fixture to open a group chat's Room
details pane and verify distinct online-participant and offline-member sections.
Offline rows open the same member-details screen as online participants, with
direct messaging, affiliation changes, and bans subject to the same owner/admin
permissions. Kick and voice controls remain online-only. Offline actions target
real bare JIDs, and affiliation caches update only after a successful server
acknowledgement. Online anonymous participants retain nickname-based moderation
and room-private messaging.

The room-controls tests also use `DINO_UI_TEST_ROOM_AFFILIATION` to cover owner,
admin, and ordinary-member permissions, online-only controls, and cancellation
of a ban confirmation on iOS and Catalyst. Room protocol parsing is covered by
`MUCTests` in GeckoKit, and moderation end to end by the live `room-admin` step.

`LoginUITests` uses `DINO_UI_TEST_FIXTURE=login` to bypass core startup without
loading or changing stored accounts. Run it with
`-only-testing:GeckoUITests/LoginUITests` on either destination. It covers the
width-limited, safe-area-centered login panel, address-to-password Return-key
focus, credential-dependent button availability, and large-text scrolling on
iOS. The tests do not submit credentials or exercise server authentication.

Website screenshots come from `DINO_UI_TEST_FIXTURE=showcase`: invented
contacts, a group chat and a CC0 lake photo from Wikimedia Commons (the script
downloads it once into `build/shots/`), with times anchored to 9:41.
`scripts/screenshots.sh [ios|mac|all]` builds Debug, opens the list (iPhone
only), a one-to-one chat and the group (`DINO_UI_TEST_OPEN_JID`) in light and
dark, and writes `build/screenshots/{ios,mac}/`. The iPhone run uses the
Simulator named "Gecko Shots iPhone" with an overridden status bar. The Mac run
starts a second instance beside any installed Gecko, briefly switches the system
to dark mode (Catalyst ignores a per-app override) and restores it, and needs
Screen Recording and Accessibility for the terminal. Mac shots are 2560×1600
(a 1280×800 window), a Mac App Store size. For iPhone App Store sizes, point
`GECKO_SHOTS_SIM` at an "iPhone 17" Simulator (1206×2622) and set
`GECKO_SHOTS_OUT` to keep them apart from the website set.

Composer tests establish a post-keyboard baseline, then check each inserted
character and backspace across soft wraps and explicit line breaks. The image
test measures the actual preview button, not an inherited row identifier.
XCTest still waits for idle around input, so inspect recorded frames when
checking transient jumps that could disappear before an assertion runs.

On iOS, `AppDelegate` configures the shared `AVAudioSession` category as
`.playback` at launch, before either attachment player can run. This keeps audio
and video on media volume and allows playback in Silent mode. Activation remains
deferred until playback, so opening Gecko alone does not interrupt other audio.
Mac Catalyst's audio policy and the existing background-playback behavior are
unchanged. Verify the volume buttons and Silent mode on a physical iPhone; the
Simulator can check the session category and playback lifecycle, not those
hardware behaviors.

Audio attachment regressions use `DINO_UI_TEST_AUDIO=1` with the
`chat-visibility` fixture: locally generated PCM audio plus a corrupt file,
without an account or network access. The audio cases in
`ChatVisibilityUITests` exercise switching, seeking to the end, replay, and
failure UI with sharing preserved on both iOS and Catalyst. Save-button coverage
checks the native Files picker and cancellation on iOS, and exports the audio
under its original filename with intact PCM samples on Catalyst.
Sharing coverage checks the popover's distance from two tapped audio buttons on
Catalyst and completing/reopening the share sheet on iOS. Save and share use
matching plain SwiftUI buttons with adjoining 44-point tap targets. An invisible
UIKit view behind share supplies the popover anchor, avoiding both Catalyst's
native button bezel and `ShareLink`'s inferred geometry inside a scrolling chat.
The Catalyst attachment context menu also offers Share alongside Save As for
completed local files of any type. It reuses the same UIKit presenter with an
anchor behind the attachment content, not the row or app window. The image
context-menu regression checks popover proximity and dismissal/reopening.

The custom reaction picker keeps its SwiftUI sheet, quick reactions, and search.
On Catalyst its full catalog uses fixed-size, reusable `UICollectionView` cells
instead of SwiftUI grid buttons; iOS retains the original lazy grid. Filtering
is evaluated once per body, and unrelated updates do not reload native cells.
`testCustomReactionPickerSearchToggleAndCancelPreserveDraft` checks searching,
adding/removing a reaction, reopening, clearing search, and cancellation. The
DEBUG fixture updates reactions locally with a message revision bump; it does
not call the unstarted XMPP core or verify server delivery.

Run the complete Catalyst UI suite (including the shared media/scroll tests and
`CatalystInteractionUITests`) on an unlocked Mac desktop:

```sh
xcodebuild test -project Gecko.xcodeproj -scheme Gecko \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -derivedDataPath /tmp/GeckoCatalystUITests \
  -resultBundlePath /tmp/GeckoCatalystUITests.xcresult \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=998J34UYP5 \
  ENABLE_HARDENED_RUNTIME=NO
```

Choose unused output paths for a fresh run. A local Apple Development identity
and team are required; the team override restores the value cleared by the
normal ad-hoc Catalyst app configuration. The identity/hardened-runtime
overrides avoid the test runner being killed before bootstrapping on the current
host. These are test-command overrides, not release signing settings. Keep UI
runners serial: the keyboard, Dock, clipboard, and native dialogs are shared.

The desktop-only interaction tests reuse the account-free `chat-visibility`
fixture. They cover main-window close/Dock reopen and app hide/activation with
draft preservation, initial and conversation-switch composer autofocus,
Return versus Shift-Return, Command-N Contacts and cancellation,
Command-comma Settings and Escape, text Copy/Reply cancellation, repeated
main-window corner resizing against a 5,000-message fixture with chat/editor
responsiveness, and repeated secondary-media-window closure.
Composer submission checks local draft/focus behavior, not XMPP delivery.
Native window counts use direct application children because Catalyst also
exposes nested UIKit accessibility windows. Reopening the closed main window
uses the newly launched test app's Dock icon; `XCUIApplication.activate()` alone
does not deliver the native reopen event.
`testClosedWindowReopensAfterApplicationDelegateReplacement` uses the DEBUG-only
`DINO_UI_TEST_REPLACE_APP_DELEGATE=1` hook to restore the framework's application
delegate when closing the window, then switches to Finder and clicks the Dock
icon twice. It checks that one chat window returns with its draft and keyboard
input intact. This fault-injection case failed before the native activation
fallback and passed with it; it does not simulate hours of idle time or sleep.

Catalyst Contacts uses a native `UISearchTextField` so clearing updates both the
visible editor and the search binding. Its regression in `ChatVisibilityUITests`
checks two clear cycles with screenshot OCR of the restored placeholder, then
checks that subsequent typing starts empty; an empty accessibility value alone
can miss stale rendered text. The GIF/WebP tests likewise inspect actual pixels:
screenshots are sampled directly within a deadline instead of a predicate
waiter. This removes the waiter that interrupted an in-flight accessibility
snapshot during verification; screenshot/decode errors still fail the test.

The typing indicator uses plain caption text over a subtle full-width background
gradient, not a glass capsule. An 18pt caption-scaled strip is always reserved in the
list's bottom clearance, so typing changes never move the messages. The indicator
sits just above the composer's visible edge, outside measured composer geometry.

The chat's composer clearance lives in the non-lazy bottom anchor, not a bottom
content margin. Together with `.defaultScrollAnchor(..., for: .sizeChanges)`,
this keeps multiline growth/deletion bottom-aligned during layout. Changing
content margins and correcting afterward can briefly restore an estimated
older row before snapping back. Disable resize anchoring while the user is
scrolling or reading older messages; keep initial positioning explicit.

New live bubbles use a short scale-and-fade entrance on iOS and Mac Catalyst
while following the newest messages. The transition affects only the inserted
row's drawing; stack layout and viewport movement remain owned by the existing
bottom-scroll coordinator. Initial/history loads, synchronized messages, and
Reduce Motion do not animate bubble insertion. Simulator frame captures verified
incoming/outgoing entrances, bottom following, and the Reduce Motion opt-out.
Arrival and send-scroll requests share any active bottom animation rather than
restarting its easing curve. The driver tracks the live bottom as more messages
arrive; user gestures still cancel it. A Catalyst send fixture verified that a
delayed send-scroll request preserves monotonic progress through completion.

Existing bubbles animate content-driven size changes over 0.25 seconds, including
the switch from a download row to an image preview. This animation is scoped to
the message bubble, not the list, and is disabled by Reduce Motion. Image header
size reservation remains unchanged, so thumbnail decoding adds no second resize.
Simulator captures verified the intermediate download-to-preview sizes and the
instant size change with Reduce Motion enabled.

Message bodies keep their full intrinsic height at the available bubble width
(`fixedSize(horizontal: false, vertical: true)`), so long plain text and mixed
quote/text messages are not vertically truncated. The
`testLongMessageTailIsRenderedForPlainAndQuotedBodies` UI regression uses
`DINO_UI_TEST_LONG_MESSAGE=plain|quoted` and screenshot OCR to verify the final
line of an 80-line body; accessibility text alone cannot detect visual clipping.

Row visibility and history anchors are measured from passive UIKit row
backgrounds during coalesced post-layout scroll work. Keep per-row SwiftUI
`onGeometryChange`/scroll-visibility observers out of the lazy stack: Catalyst
can loop in AttributeGraph row placement and coordinate-space resolution before
observer actions run, so deferring those actions alone does not prevent a hang.
The native probes are weakly registered and do not publish geometry into
SwiftUI state during layout. They enqueue a post-layout sample only on window
attachment or when a row's height changes; width-only viewport changes remain
covered by the outer scroll geometry observer.
Visibility and history-anchor calculations use the native scroll view's bounds
height, matching the UIKit row frames. SwiftUI's container height already omits
the top content margin; using it here excludes that space twice and can leave
the newest row falsely invisible, keeping older-history loading disabled.
`DINO_UI_TEST_HISTORY=1` provides 150 messages through the normal history event
handlers in 50-item pages. The desktop
`testScrollingUpLoadsSuccessiveHistoryPages` regression scrolls beyond the
initial page through to message 1, rather than only scrolling cached rows.

On Catalyst, a large width reflow can reach the non-lazy bottom anchor while
the adjacent newest `LazyVStack` row is still de-materialized. The post-layout
sample detects that bottom-without-newest state once per container height,
materializes the stable newest message ID, then returns to the composer
clearance anchor. Visibility reduction scans only live native probes, so its
cost stays bounded by materialized rows rather than total loaded history.

Latest-history refreshes preserve loaded older rows only when the new raw page
overlaps the previous raw latest page. A disjoint refresh replaces the cached
window and resets its older-page cursor, so messages received during suspension
remain reachable by scrolling back. Unsupported raw items count as overlap;
isolated live updates do not. `HistoryPaginationTests` covers gap recovery and
stale in-flight responses (`swift test --package-path GeckoKit`).

## Voice calls

One-to-one voice calls are written in Swift on the prebuilt WebRTC framework.

| Piece | Where | Role |
| --- | --- | --- |
| Signalling logic | `GeckoKit`: `CallSession.swift`, `CallJingle.swift`, `StanzaNode.swift` | Pure state machine for one call plus the Jingle XML: Jingle Message Initiation (XEP-0353), session-initiate/accept/terminate and trickled candidates (XEP-0166/0167/0176), DTLS fingerprints (XEP-0320). Covered by `CallSessionTests`. |
| SDP mapping | `GeckoKit`: `CallSDP.swift` | Between WebRTC's SDP and the values Jingle carries (Opus only). Covered by `CallSDPTests`. |
| Glue | `App/CallSignaling.swift` | Runs one `CallSession` over the connection, asks the server for STUN/TURN servers (XEP-0215), drives the engine. |
| Media | `App/CallEngine.swift` | One audio-only `RTCPeerConnection` from the prebuilt WebRTC framework (ICE, DTLS-SRTP, Opus, echo cancellation). `TurnShimProxy` puts a loopback UDP hop in front of each UDP TURN server. |
| Ring tones | `GeckoKit`: `CallTone.swift`, played by `CallEngine` | While a call rings the caller hears a ringback tone and the callee a ring, both synthesised (no audio files) and looped. On iOS the ring obeys the silent switch; ringback uses the call's own audio category, so it plays in the earpiece. Covered by `CallToneTests`. |
| TURN shim | `GeckoKit`: `TurnAuthShim.swift` | Makes a TURN server that grants requests without authenticating look authenticated to WebRTC. Covered by `TurnAuthShimTests`. |
| UI | `App/CallView.swift`, call button in the chat toolbar | Floating call card: incoming prompt, mute, speaker (iOS), hang up. |
| Stanza passthrough | `SwiftCore` (its Calls section) | `sendStanza` and `{"type":"stanza"}` events: advertises the call features, hands over one-to-one Jingle Message Initiation messages (live, and carbons from our own account) and the Jingle requests of call sessions (tracked by sid), and returns the answers to CallSignaling's requests. Off in the notification extension. |

Limits of this first step: audio only; one call at a time; outgoing calls
always start with a Jingle Message Initiation proposal (no direct
session-initiate fallback); a proposal that includes video is not offered to
the user; no ringing timeout; nothing rings while the app is closed. When the
account's server offers no STUN/TURN service, `stun.dino.im:7886` is used, the
same fallback as desktop Dino.

WebRTC only takes relay candidates from a TURN server that authenticates: it
drops an allocation granted without a challenge (`Discarding unauthenticated
success response` in its log, hard-coded in `stun_request.cc`). `turn.xmpp.is`
granted them that way in November 2026, so calls from accounts there failed
about 15 s in whenever the peer had no direct path. `TurnAuthShim` covers for
such servers: it answers WebRTC's first Allocate with its own 401 challenge and
signs the server's later replies with the key WebRTC derives from it. The cost
is that TURN replies are no longer proven to come from the server, so someone
on the path to it can redirect or break the relayed leg; the media stays
DTLS-SRTP. A server that challenges is passed through, and `turn:` over TCP
goes to the server directly. `RTCSetMinDebugLogLevel(.info)` shows the
allocation exchange.

Headless check between two accounts: `DINO_AUTOCALL=<jid>` places a call once
connected, `DINO_AUTOANSWER=1` answers after a second, `DINO_AUTOHANGUP=<s>`
hangs up that long after the call connects. Both sides log `gecko-call:` lines,
including RTP packet counters for the first ten seconds. In the Simulator,
grant the microphone first (`xcrun simctl privacy booted grant microphone
me.anemoneya.gecko`). `DINO_CALL_RELAY_ONLY=1` restricts that side to relay
candidates, which is how the TURN path is exercised on one network.

## Design notes / gotchas

* **Static linking.** iOS forbids loading unsigned dylibs, so libomemo-c,
  protobuf-c and GRDB are static; only WebRTC is an embedded framework.
* **Threading.** `SwiftCore` lives on the main actor; each account's
  `XMPPClient` is an actor that owns its connection. `GeckoCore` takes commands
  from any thread and runs them on the main queue in order; events are
  JSON-shaped dictionaries, so `AppModel` decodes them as it always did.
* **Storage.** `xdg-data/gecko/` (the App Group container on iOS, per-app
  Library on Catalyst) holds `gecko.sqlite` and received files. A Dino-based
  build's `xdg-data/dino/` is imported once, and its files and avatar cache are
  still read in place. The store waits up to 5 s on the extension's lock.
* **Sessions.** Each account connects with its stored resource (kept from
  Dino on import), the same every launch, so a new session replaces one the
  server still holds for resumption instead of standing beside it; quitting
  closes the streams (`applicationWillTerminate`). With a random resource per
  launch, every killed launch left a session the server kept "available" for
  its resumption timeout, so contacts saw us online after we had quit. The
  extension uses its own stable resource so it never takes the app's session.
  Presence is cleared only for a new session; a resumed one keeps it.
* **Passwords** live in the Keychain, in the App Group access group on iOS so
  the extension can sign in (moved there on first read).
* **Live-only message cache**: live arrivals are cached in `AppModel.messages`
  even for chats that have not been opened (Mac notification de-duplication
  reads them). That partial list is dropped when the chat becomes the
  navigation target, before it renders. Rendering it let the message list do
  its initial positioning on one or two rows; the first history page then
  landed above them with the same newest ID, so nothing re-pinned, and on
  Catalyst the chat could stay at the top of the page with the scroll-down
  button hidden.
* **Attachment transport preview**: the composer asks the core how a staged
  file would travel before sending. The answer is HTTP upload, or a reason
  (no upload service, or the file is over the server's limit). Preview replies
  are request-correlated and discarded after cancellation or navigation.

## Notification Service Extension (in progress)

Per-conversation notification settings (off / mentions-only) cannot be
enforced server-side: Gecko is general-purpose, and public servers strip
sender+body from XEP-0357 push summaries for privacy (xmpp.is sends only a
count; Prosody defaults sender off too), so the proxy never learns which
conversation a push belongs to. The fix is on-device filtering in an NSE —
works on any server and also unlocks decrypted previews.

* **Storage:** on iOS the store lives in the `group.me.anemoneya.gecko`
  App Group container and passwords in its keychain group, so the extension
  reads both. The local Catalyst build uses per-user Library/Caches roots:
  local notifications need no sharing, and avoiding an unentitled App Group
  lookup keeps macOS from asking for cross-app data access on every launch.
* **Fetch (done, Simulator):** `NSEFetcher` runs `SwiftCore` in its
  notification mode: no stream management, presence or room joins, just the
  account's and open rooms' archives, stored and decrypted (no OMEMO repair or
  key publishing) into the shared store. It returns each incoming message with
  its conversation, sender and notify setting, plus the unread total;
  `NotificationService` enriches the alert and sets the badge. Preview
  selection uses the last unmuted message and counts only eligible messages in
  its subtitle; a nonempty, entirely muted batch becomes badge-only, and an
  empty fetch keeps the original push content. Encrypted room messages are not
  read here (no members' real JIDs without joining). Still to confirm on a
  device, where the 24 MB / 30 s budget is enforced.
* **Phase 3 (todo, gated):** suppress muted-conversation banners. Requires
  the `com.apple.developer.usernotifications.filtering` entitlement (Apple
  request on the dev account); enrichment in Phase 2 works without it.
* **Mac Catalyst local filtering (done):** the persistent Mac process posts
  local notifications for new live incoming items only while Gecko is not
  active. It suppresses muted conversations and non-mention MUC messages before
  scheduling and updates the Dock icon badge from the aggregate unread
  count, so this path needs notification permission but no APNs or filtering
  entitlement. It intentionally does not notify after Gecko quits.
  Remote NSE suppression on macOS still requires Apple's same
  [`com.apple.developer.usernotifications.filtering`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.filtering)
  managed entitlement plus an APS-signed Catalyst profile.

Host-only notification selection regression (no account, store, or APNs):

```sh
swiftc NotificationService/NotificationService.swift NotificationService/Tests/main.swift -o /tmp/gecko-nse-check
/tmp/gecko-nse-check
```

## Next steps

1. Notification extension: device check, then Phase 3 (above).
2. Calls: video, CallKit plus VoIP pushes so calls ring when the app is
   closed, group calls.
3. CI for the dependency build and the live script.
4. Stream management across launches: `XMPPClient` resumes a session within
   one process; persisting the resumption state (id, counters, unacknowledged
   stanzas) to the App Group, with a lock so the app and the extension never
   own one stream at once, would skip re-login and archive catch-up on launch.

Done beyond the basics: contact management (roster, presence,
subscription requests), sign in/out with stable OMEMO identity, avatars,
conversation previews/unread counts and app icon badges/read markers
(XEP-0333), typing notifications (XEP-0085), file transfers (HTTP upload via
OMEMO-encrypted aesgcm files, photo-library uploads that preserve animated GIF
and WebP files, memory-bounded inline GIF/WebP playback controlled by
tap-to-play/tap-to-pause format badges, and SVG previews/viewers rasterized in
a bounded, script-disabled, nonpersistent WebKit image document. SVGs with XML
document type or entity declarations are rejected. Static images still open
full-screen),
MUC management (join/leave, mediated and direct invitations, participant list,
per-sender avatars/nicks),
emoji reactions (XEP-0444), message corrections (XEP-0308), replies
(XEP-0461), delivery markers, account settings (avatar publishing,
display name, password change, OMEMO fingerprint), TLS via the iOS trust
store, fast reconnect on foreground, client identity "Gecko" (phone),
verified device deployment (`scripts/deploy-phone.sh`), and **push
notifications**: XEP-0357 + the containerized proxy in push-proxy,
hosted on k8s (namespace `gecko`), verified end to end through APNs.
