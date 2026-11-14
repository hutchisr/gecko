# AGENTS.md

Orientation for AI agents (and humans) working in this repository.

## What this repo is

**Gecko**: an XMPP messaging app for iOS and Apple Silicon Macs (Mac Catalyst),
written in Swift and SwiftUI. It began as a fork of **[Dino](https://dino.im)**
that kept Dino's Vala/GLib core under a SwiftUI front end; that core has been
replaced by Gecko's own XMPP core in Swift, and the Vala tree, the C bridge,
Meson and the GLib stack are gone (`ios/MIGRATION.md` has the history). What
remains of Dino is `DinoImport`, which moves a Dino-based install's data into
the Swift store on first launch. `README.md` is the user-facing intro.

License: **GPL-3.0** (`LICENSE`). The app links libomemo-c (GPL), which keeps
it GPL; see the licensing memory. `ios/push-proxy/` is separately MIT.

The longer reference is **[`ios/PORTING.md`](ios/PORTING.md)**: layout,
calls, push and the notification extension, the live test script, UI notes.
This file is the shorter "how to work here" companion.

## Architecture in one screen

```
┌─────────────────────────────────────────────┐
│ SwiftUI app  (ios/app/Sources/*.swift)       │  GeckoApp.swift = the UI
│   AppModel (Model.swift) ── @Published state │  Model.swift   = state + event decode
└───────────────▲──────────────┬──────────────┘
                │ JSON-shaped   │ commands
                │ events        │ (GeckoCore)
┌───────────────┴──────────────▼──────────────┐
│ SwiftCore  (GeckoKit/Sources/GeckoKit/XMPP)  │  accounts, chats, rooms, OMEMO,
│   RoomCoordinator, OMEMOCoordinator, …       │  files, push, call signalling
│   XMPPClient (actor per account)             │  TLS, SCRAM, stream management
│   GeckoStore (GRDB)                          │  gecko.sqlite in the App Group
└───────────────▲──────────────────────────────┘
                │ static-linked
        libomemo-c + protobuf-c, GRDB; WebRTC.framework (calls)
```

- `GeckoCore` takes commands from any thread and runs them on the main actor
  in order; `SwiftCore` emits events as JSON-shaped dictionaries that
  `AppModel.handle` decodes.
- Everything but WebRTC is statically linked (iOS forbids loading unsigned
  dylibs).
- The notification extension (`ios/nse`) runs `SwiftCore` in its notification
  mode against the same store and keychain group.

## Directory map

|Path|What|
|---|---|
|`ios/PORTING.md`|**Read first.** The reference: layout, calls, push, NSE, live tests, UI notes.|
|`ios/MIGRATION.md`|How the Dino core was replaced, phase by phase.|
|`ios/build-deps.sh`|Builds protobuf-c, libomemo-c, GRDB and fetches WebRTC into `ios/prefix/<target>` (about a minute).|
|`ios/app/Sources/`|The SwiftUI app. `GeckoApp.swift` (views), `Model.swift` (`AppModel`, event decode), `GeckoCore.swift` (the door to the core), plus per-screen files.|
|`ios/app/GeckoKit/`|SwiftPM package: the XMPP core (`Sources/GeckoKit/XMPP/`), `COMEMO` (libomemo-c module), and pure helpers. Unit-tested on the host.|
|`ios/app/GeckoXMPP/`|**Scaffold only** (empty). Nothing depends on it.|
|`Gecko.xcodeproj`|App + Notification Service Extension targets linking `ios/prefix/<target>`. **Every new GeckoKit source must also be added here, to both targets.**|
|`ios/app/build-app.sh`|Builds `Gecko.app` (and the extension) with plain `swiftc`; `run` installs and launches in the Simulator.|
|`ios/app/deploy-phone.sh`|Build + re-sign + install on a physical iPhone via `devicectl`.|
|`ios/app/deploy-testflight.sh`|Archive + upload to TestFlight.|
|`ios/nse/`|Notification Service Extension (`NotificationService.swift`, `NSEFetcher.swift`).|
|`ios/live-test/`|Live two-account check against xmpp.is (`run.sh`).|
|`ios/push-proxy/`|Standalone MIT-licensed Rust XEP-0357 → APNs proxy, containerized for k8s namespace `gecko`. Run `cargo test --locked` in that directory.|
|`ios/udid-enroll/`, `ios/dist-host/`|Ad-hoc device enrollment + IPA distribution host (containerized).|

## Build, run, test

```sh
# Once per target: the libraries the app links
ios/build-deps.sh sim-arm64          # or device-arm64, catalyst-arm64

# Build + run in the Simulator
ios/app/build-app.sh run sim-arm64   # ACTION defaults to "build", TARGET to "sim-arm64"

# Mac (Catalyst)
ios/app/build-app.sh run catalyst-arm64

# Physical device (phone must be connected; on request only)
ios/app/deploy-phone.sh "iPhone 18 Pro Max"

# Unit tests: host, fast, no Simulator
cd ios/app/GeckoKit && swift test

# Live end-to-end check (one run at a time; name the Simulator)
GECKO_SIM_DEVICE=<udid> ios/live-test/run.sh [steps…]

# Lint (config tuned in .swiftlint.yml: bug rules on, style noise off)
swiftlint
```

## Conventions

- **GeckoKit = one source of truth, two compilations.** The core and pure
  helpers live in `GeckoKit/Sources/GeckoKit/` (including `XMPP/`).
  `build-app.sh` **globs those files straight into the app and the extension**,
  and `swift test` exercises the *same* files on the host. Put anything
  testable and UI-free there and add tests. UIKit/ImageIO-only code goes behind
  `#if canImport(UIKit)`; keep the pure parts ungated so they stay testable.
- **Protocol code is written from the RFCs and XEPs**, not translated from
  Dino's Vala.
- **Swift style**: match the surrounding code. Short local names (`e`, `c`,
  `jid`, `me`) are idiomatic here; `AppModel` and `SwiftCore` are
  intentionally large; trailing commas in multi-line literals are intentional.
- **Commit messages**: `area: imperative summary — elaboration`, e.g.
  `ios: reserve image row height so chats open pinned to the bottom`,
  `ios/nse: ...`, `push-proxy: ...`. Body explains the *why*. Commit only when
  asked; work happens on `master`.

## Working in the Simulator (hard-won operational notes)

- **Headless automation**: the app reads `DINO_*` env vars (passed via the
  `SIMCTL_CHILD_` prefix) to drive itself, e.g. `DINO_AUTOPEER=jid` (start and
  open a chat), `DINO_AUTOOPEN=jid`, `DINO_AUTOSEND=text`,
  `DINO_AUTOSENDFILE=1`, `DINO_AUTOOMEMO=1`, `DINO_LOG_XMPP=all` (every stanza
  on the console), `DINO_LIVE_TEST=1` (`gecko-live:` event lines). Defined in
  `Model.swift` (`setupAutomationHooks` / `runConnectedAutomation`); the full
  list is in `ios/PORTING.md`.
- **Logs**: `NSLog` shows up in `xcrun simctl spawn <udid> log stream
  --predicate 'process == "Gecko"'` and in `simctl launch --console-pty`. The
  extension's log reaches `log show` minutes late; check its effect in the
  store instead.
- **Several Simulators may be booted**: always name the device (`<udid>`), never
  `booted`; never run two live runs or launches at once.
- **Refreshing a build: `simctl install` over the top, never `uninstall`.**
  Uninstall wipes the app's data container, including the logged-in account.
- **Stale-binary trap**: after installing, confirm the running code is fresh by
  grepping the binary for a marker string before trusting a "no log output"
  result.
- **Test accounts**: `geckotest@xmpp.is` (the app account) and
  `geckotest2@xmpp.is` (the live script's peer); the user's own account is
  `anemone@xmpp.is`. Live secrets are in **`credentials.local.txt`**
  (gitignored): read it **only when the user explicitly directs**.
- **Phone deploys are on request only**; default to Simulator verification.
  Since iOS 26.4 a development build must be verified online by Apple
  (`ppq.apple.com`) before it first runs; when that fails ("Unable to Verify
  App"), use TestFlight or the Mac build.

## State of the work

Working end to end against real servers: login, roster, presence, one-to-one
chats with markers, typing, reactions, replies and corrections, OMEMO (legacy
namespace, via libomemo-c), group chats with moderation and private-room
OMEMO, HTTP file sharing (encrypted, cancellable, resumable downloads), push
(XEP-0357 → `ios/push-proxy` → APNs) with on-device fetch in the extension,
and one-to-one voice calls. Not done: video and group calls, ringing while
closed, OpenPGP, OMEMO 2, CI, and device checks of the extension's budget.

## Deeper references

- `ios/PORTING.md`, `ios/MIGRATION.md`.
- `ios/app/TESTFLIGHT.md`, `ios/PRIVACY.md`: release and privacy notes.
- `ios/push-proxy/README.md`, `ios/nse/`: push subsystem.
- Project memory (auto-loaded): memories reflect what was true when written;
  verify a named file or flag still exists before relying on it.

- For repository collaboration, use ngit and follow `.agents/skills/ngit/SKILL.md`.
