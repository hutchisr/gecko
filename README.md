<img src="App/AppIcon.png" width="80">

# Gecko

Gecko is an XMPP messaging app for iOS and Apple Silicon macOS, written in
Swift and SwiftUI. It supports OMEMO encryption, group chats, file transfers,
push notifications, voice calls and more.

On first launch after an update from an older Gecko version, Gecko brings its
history, keys and passwords across. iPhone and Mac Catalyst share one SwiftUI
application.

Status
------
Working end to end against real servers:

- Login over direct TLS or STARTTLS with SCRAM, stream resumption, roster and
  bookmark sync, contact management
- One-to-one and group chats (MUC), including invitations, per-sender avatars,
  and nicks
- **OMEMO** encryption (libomemo-c) in chats and private rooms, with a stable
  device identity
- File transfers over HTTP upload, OMEMO-encrypted, with inline image previews,
  cancel, and downloads that resume
- Reactions (XEP-0444), corrections (XEP-0308), replies (XEP-0461),
  read markers (XEP-0333), typing notifications (XEP-0085)
- **Notifications** — iOS uses XEP-0357 through the bundled push proxy and an
  on-device Notification Service Extension. While the Mac Catalyst app is
  running, it posts local notifications from its live XMPP stream and applies
  each conversation's off / mentions-only setting before delivery. On both
  platforms the app icon badge shows the total unread message count.

Downloaded audio attachments have inline play/pause, seeking, saving, and sharing on
iOS and Mac Catalyst. Playback uses the system's native codecs (no bundled
decoders); unsupported or damaged files show an error and remain shareable.
Starting another audio attachment pauses the previous one. Leaving the
attachment stops playback; iOS also pauses when the app enters the background.
On iOS, audio and video use media volume rather than Ringer and Alerts volume,
and remain audible with Silent mode enabled.

Outgoing attachments preserve their filenames. Temporary copies live in unique
staging directories, so selecting same-named files does not add UUID prefixes to
the uploaded names.
Drag a file from Files or Finder onto the chat or message field to prepare an
attachment, then use its Send button. Drops use the same preview, cancellation,
and 512 MiB staging limit as picked files. Attach one file at a time; folders
are not supported.

One-to-one voice calls work while Gecko is open (tested between two Gecko
installs so far). They are audio only, and a call does not ring when the app
is closed.

Not implemented: video calls, OpenPGP, OMEMO 2, and full JID stringprep (a
casefold is used instead).

There is no public release yet; iOS builds are distributed via TestFlight and
sideloading. macOS uses an Apple Silicon Mac Catalyst build.

Build
-----
Requires macOS with Xcode 26. iOS and Mac Catalyst currently target version 26
or later.

For an iOS Simulator:

    scripts/build-deps.sh sim-arm64
    scripts/build-app.sh run sim-arm64

For an Apple Silicon Mac:

    scripts/build-deps.sh catalyst-arm64
    scripts/build-app.sh run catalyst-arm64

`build-deps.sh` builds the few libraries the app links (libomemo-c,
protobuf-c, GRDB) and fetches the WebRTC framework, in about a minute.

Use `device-arm64` to build for a physical iPhone. Once the matching static
prefix exists under `build/prefix/<target>`, you can also open `Gecko.xcodeproj`
and build the shared `Gecko` scheme for iPhone, Simulator, or Mac Catalyst.

Unit tests for the XMPP core and the pure Swift helpers run on the host,
without a Simulator:

    cd GeckoKit && swift test

Resources
---------
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how Gecko is built and tested: layout,
  calls, push and the notification extension, the live two-account script.
- [`docs/MIGRATION.md`](docs/MIGRATION.md) — how Gecko's XMPP core came to be.
- [`AGENTS.md`](AGENTS.md) — orientation for working in this repository.
- [`docs/PRIVACY.md`](docs/PRIVACY.md), [`docs/TESTFLIGHT.md`](docs/TESTFLIGHT.md) — privacy and release notes.

License
-------
Gecko's source code is released under the [MIT License](LICENSE).

Gecko links [libomemo-c](https://github.com/dino/libomemo-c) for OMEMO
encryption, which is licensed under the GPL-3.0. Builds of the app that include
it, such as TestFlight and App Store builds, are therefore distributed under
the terms of the GPL-3.0 as a whole; the MIT-licensed source stays MIT. The
other bundled libraries keep their own licenses: GRDB (MIT), protobuf-c
(BSD-2-Clause) and WebRTC (BSD-3-Clause).
