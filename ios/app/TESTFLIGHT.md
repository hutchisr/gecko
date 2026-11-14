# TestFlight

The clean way to get builds to testers: no UDIDs, no Developer Mode, automatic
updates. More upfront setup than ad-hoc, most of it one-time in App Store
Connect.

The release script supports iOS (`device-arm64`, the default) and Apple Silicon
Macs (`catalyst-arm64`, macOS 26+). Both use `me.anemoneya.gecko`.

## One-time setup (web)

1. **App record** — App Store Connect → Apps → **+** → New App, bundle id
   `me.anemoneya.gecko`. The store *name* must be globally unique (e.g.
   "Gecko XMPP"); the on-device name stays "Gecko".
2. **Agreement** — Business → agree to the **Free Apps** agreement (TestFlight
   won't work until this is signed).
3. **API key for uploads** — Users and Access → Integrations → **App Store
   Connect API** → generate a key with the **App Manager** role. Note the
   **Key ID** + **Issuer ID**, download `AuthKey_<KeyID>.p8`, and move it to
   `~/.appstoreconnect/private_keys/`. (Keep the .p8 out of git.)
4. **iOS App Store profiles** — Developer portal → Profiles → create an **App
   Store** distribution profile for each app id (no devices), download + install:
   - `me.anemoneya.gecko` (App Groups + Push)
   - `me.anemoneya.gecko.NotificationService` (App Groups)
   (You already have the Apple Distribution cert from the ad-hoc work.)

### macOS

1. Add the **macOS platform** to the existing Gecko app in App Store Connect.
   Keep the same bundle ID; Catalyst bundle-ID derivation is disabled.
2. Sign in to the developer team in **Xcode → Settings → Accounts**, or supply
   the API key variables above. The Mac release uses Xcode automatic provisioning
   (`-allowProvisioningUpdates`) and requires permission to manage signing assets.
   Export uses an **Apple Distribution** app certificate and a **Mac Installer
   Distribution** certificate (shown in Keychain as
   `3rd Party Mac Developer Installer`), plus a Mac App Store profile.
   `TEAM_ID` overrides the default team `998J34UYP5`.
3. Build the Catalyst dependencies once, from the repository root:

   ```sh
   ios/build-deps.sh catalyst-arm64
   ```

Mac releases retain the current sandbox entitlements and do not embed the iOS
notification extension: Catalyst stays connected and uses local notifications.
The AppKit lifecycle interop remains an App Review risk documented in
[`../PORTING.md`](../PORTING.md); a successful upload is not review approval.

## Each release

```sh
# From the repository root:
ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-... ios/app/deploy-testflight.sh
ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-... ios/app/deploy-testflight.sh catalyst-arm64
```

iOS builds, App-Store-signs the app + NSE, stamps a fresh build number, packages
the IPA, and uploads. macOS incrementally rebuilds the core, archives the shared
Xcode scheme, and exports a signed `Gecko.pkg`. Archives (including dSYMs) remain
under `ios/app/build-catalyst-arm64/testflight/`; the package is in its `export/`
directory. `BUILD_NUMBER` overrides the UTC timestamp on either platform.

Use `VALIDATE_ONLY=1` with the API variables to validate without uploading.
Omit the API variables to build/export only, then upload with Transporter
or Xcode Organizer. Mac export can use the account signed into Xcode.
The iOS-only `PROFILE`, `NSE_PROFILE`, and `SIGN_IDENTITY` overrides do not
apply to Catalyst.

The existing mise credential-loading task also supports both:

```sh
mise run testflight
TARGET=catalyst-arm64 mise run testflight
```

## After upload

1. Wait ~5–30 min for processing (App Store Connect → TestFlight → Builds).
2. **Export compliance**: it'll ask about encryption. Gecko uses E2EE (OMEMO);
   answer per your situation (messaging E2EE typically "uses encryption" →
   "qualifies for exemption"). To stop the per-build prompt, add
   `ITSAppUsesNonExemptEncryption` to Info.plist once you've decided.
3. **Add testers**:
   - *Internal* (up to 100): App Store Connect users on your team — instant, no
     review.
   - *External* (up to 10,000): add by email; the **first** build needs a quick
     (~1 day) Beta App Review, then it's available.
4. Testers install the **TestFlight** app and accept the invite. Updates are
   automatic on each new upload.
