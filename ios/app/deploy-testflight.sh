#!/usr/bin/env bash
# Build, App-Store-sign and upload Gecko to TestFlight (App Store Connect).
# Unlike ad-hoc, testers need no UDID, no Developer Mode, and get auto-updates.
#
# Usage: ASC_KEY_ID=XXXX ASC_ISSUER_ID=yyyy-... ./deploy-testflight.sh [device-arm64|catalyst-arm64]
#
# One-time prerequisites (you, in the web portals):
#   1. App Store Connect → My Apps → + → New App for bundle id
#      `me.anemoneya.gecko`. The *store name* must be globally unique, so use
#      something like "Gecko XMPP" (the on-device name stays "Gecko").
#   2. Agree to the Free Apps agreement (Business section) — TestFlight needs it.
#   3. App Store Connect → Users and Access → Integrations → App Store Connect
#      API → generate a key (App Manager role). Note the Key ID + Issuer ID and
#      save AuthKey_<KeyID>.p8 to ~/.appstoreconnect/private_keys/.
#   4. Developer portal → Profiles → an *App Store* distribution profile for EACH
#      app id (no devices), download + install:
#        - me.anemoneya.gecko                     (App Groups + Push)
#        - me.anemoneya.gecko.NotificationService (App Groups)
#
# Overridable via environment:
#   SIGN_IDENTITY  iOS distribution identity (default: first "Apple Distribution")
#   PROFILE        iOS app's App Store .mobileprovision
#   NSE_PROFILE    iOS NSE's App Store .mobileprovision
#   TEAM_ID        Mac signing team (default: 998J34UYP5)
#   BUNDLE_ID      app bundle id (default me.anemoneya.gecko)
#   BUILD_NUMBER   CFBundleVersion to stamp (default: current UTC timestamp)
#   ASC_KEY_ID     App Store Connect API key id   (required for upload)
#   ASC_ISSUER_ID  App Store Connect API issuer id (required for upload)
#   ASC_APPLE_ID   App Store Connect app id, Mac uploads only (default 6779847344)
#   VALIDATE_ONLY  "1" to validate without uploading
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
TARGET="${1:-device-arm64}"
if [ "$#" -gt 1 ] || { [ "$TARGET" != device-arm64 ] && [ "$TARGET" != catalyst-arm64 ]; }; then
  echo "usage: $0 [device-arm64|catalyst-arm64]" >&2
  exit 1
fi
BUNDLE_ID="${BUNDLE_ID:-me.anemoneya.gecko}"
NSE_BUNDLE_ID="${BUNDLE_ID}.NotificationService"
APP_GROUP="group.me.anemoneya.gecko"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

if [ "$TARGET" = catalyst-arm64 ]; then
  # Let Xcode manage Mac provisioning, archive layout, and installer signing.
  TEAM_ID="${TEAM_ID:-998J34UYP5}"
  STAGE="$HERE/build-$TARGET/testflight"
  ARCHIVE="$STAGE/Gecko-$BUILD_NUMBER.xcarchive"
  PACKAGE="$STAGE/export/Gecko.pkg"
  AUTH=()
  if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    AUTH=(-authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  fi
  if [ -d "$ROOT/build-$TARGET" ]; then
    ninja -C "$ROOT/build-$TARGET"
    ninja -C "$ROOT/build-$TARGET" install
  fi
  mkdir -p "$STAGE"
  xcodebuild -project "$(dirname "$ROOT")/Gecko.xcodeproj" -scheme Gecko \
    -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$HERE/build-$TARGET/DerivedData" -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
    CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive
  OPTIONS="$STAGE/ExportOptions.plist"
  plutil -create xml1 "$OPTIONS"
  plutil -insert method -string app-store-connect "$OPTIONS"
  plutil -insert destination -string export "$OPTIONS"
  plutil -insert signingStyle -string automatic "$OPTIONS"
  plutil -insert teamID -string "$TEAM_ID" "$OPTIONS"
  plutil -insert manageAppVersionAndBuildNumber -bool NO "$OPTIONS"
  # No API-key auth here: the installer certificate is cloud-managed, and the
  # App Manager key gets a 403 for cloud-managed distribution certificates.
  # Export signs through the Xcode-signed-in account instead.
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$STAGE/export" \
    -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates
  pkgutil --check-signature "$PACKAGE"
  echo "packaged: $PACKAGE (build $BUILD_NUMBER)"
else
# --- resolve a distribution signing identity ------------------------------
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Apple Distribution[^"]*\)".*/\1/p' | head -1)}"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "error: no 'Apple Distribution' certificate in your keychain." >&2
  exit 1
fi

# --- find an App Store profile for a given app id -------------------------
# App Store = distribution (get-task-allow false) with NO provisioned devices
# (ad-hoc has devices; enterprise has ProvisionsAllDevices).
find_appstore_profile() {
  python3 - "$1" <<'EOF'
import glob, os, plistlib, subprocess, sys
want = sys.argv[1]
home = os.path.expanduser("~")
paths = glob.glob(f"{home}/Library/MobileDevice/Provisioning Profiles/*.mobileprovision") + \
        glob.glob(f"{home}/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision")
best = None
for p in paths:
    raw = subprocess.run(["security", "cms", "-D", "-i", p], capture_output=True).stdout
    try:
        pl = plistlib.loads(raw)
    except Exception:
        continue
    ents = pl.get("Entitlements", {})
    appid = ents.get("application-identifier", "")
    bid = appid.split(".", 1)[1] if "." in appid else ""
    if bid != want:
        continue
    if ents.get("get-task-allow", False) or pl.get("ProvisionedDevices") or pl.get("ProvisionsAllDevices"):
        continue   # not App Store
    has_groups = "com.apple.security.application-groups" in ents
    exp = pl.get("ExpirationDate")
    score = (has_groups, exp.timestamp() if exp else 0)
    if best is None or score > best[0]:
        best = (score, p)
if best:
    print(best[1])
EOF
}

PROFILE="${PROFILE:-$(find_appstore_profile "$BUNDLE_ID")}"
NSE_PROFILE="${NSE_PROFILE:-$(find_appstore_profile "$NSE_BUNDLE_ID")}"
for v in "PROFILE:$BUNDLE_ID:$PROFILE" "NSE_PROFILE:$NSE_BUNDLE_ID:$NSE_PROFILE"; do
  name="${v%%:*}"; rest="${v#*:}"; bid="${rest%%:*}"; path="${rest#*:}"
  if [ -z "$path" ]; then
    echo "error: no App Store profile for $bid." >&2
    echo "  Create an App Store distribution profile for App ID '$bid'," >&2
    echo "  download + install it, then re-run. (Or set $name=...)" >&2
    exit 1
  fi
done

TEAM_ID=$(security cms -D -i "$PROFILE" 2>/dev/null | plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null || true)
echo "identity:    $SIGN_IDENTITY"
echo "team:        $TEAM_ID"
echo "app profile: $PROFILE"
echo "nse profile: $NSE_PROFILE"
echo "build:       $BUILD_NUMBER"

# --- build ----------------------------------------------------------------
if [ -d "$ROOT/build-device-arm64" ]; then
  ninja -C "$ROOT/build-device-arm64" >/dev/null
  ninja -C "$ROOT/build-device-arm64" install >/dev/null
fi
"$HERE/build-app.sh" build device-arm64

# --- stage + re-sign (App Store distribution) -----------------------------
STAGE="$HERE/build-device-arm64/testflight"
APP="$STAGE/Gecko.app"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$HERE/build-device-arm64/Gecko.app" "$STAGE/"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Info.plist"
# App Store requires a monotonically increasing build number, matched app+NSE.
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Info.plist"
cp "$PROFILE" "$APP/embedded.mobileprovision"

cat > "$STAGE/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>$TEAM_ID.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM_ID</string>
	<key>get-task-allow</key>
	<false/>
	<key>aps-environment</key>
	<string>production</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$APP_GROUP</string>
	</array>
	<key>keychain-access-groups</key>
	<array>
		<string>$TEAM_ID.$BUNDLE_ID</string>
	</array>
</dict>
</plist>
EOF

# Embedded frameworks take the same identity but no entitlements or profile;
# sign them before the bundles that seal them.
codesign -f -s "$SIGN_IDENTITY" --timestamp "$APP/Frameworks/WebRTC.framework"

APPEX="$APP/PlugIns/NotificationService.appex"
if [ -d "$APPEX" ]; then
  plutil -replace CFBundleIdentifier -string "$NSE_BUNDLE_ID" "$APPEX/Info.plist"
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APPEX/Info.plist"
  cp "$NSE_PROFILE" "$APPEX/embedded.mobileprovision"
  cat > "$STAGE/nse-entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>$TEAM_ID.$NSE_BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM_ID</string>
	<key>get-task-allow</key>
	<false/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$APP_GROUP</string>
	</array>
</dict>
</plist>
EOF
  codesign -f -s "$SIGN_IDENTITY" --timestamp --entitlements "$STAGE/nse-entitlements.plist" "$APPEX"
fi
codesign -f -s "$SIGN_IDENTITY" --timestamp --entitlements "$STAGE/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"

# --- package IPA ----------------------------------------------------------
rm -rf "$STAGE/Payload" "$STAGE/Gecko.ipa"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry Gecko.ipa Payload && rm -rf Payload)
echo "packaged: $STAGE/Gecko.ipa (build $BUILD_NUMBER)"
PACKAGE="$STAGE/Gecko.ipa"
fi

# --- validate / upload to App Store Connect -------------------------------
if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
  echo
  echo "Built + signed for the App Store. To upload, set ASC_KEY_ID and"
  echo "ASC_ISSUER_ID (and put AuthKey_<KeyID>.p8 in ~/.appstoreconnect/private_keys/),"
  echo "then re-run — or upload $PACKAGE via the Transporter app."
  exit 0
fi

action="--upload-package"
[ "${VALIDATE_ONLY:-}" = "1" ] && action="--validate-app"
echo "running altool $action ..."
# altool looks the app up by platform, and Gecko's record has no macOS store
# version, so the Mac lookup fails unless the app's Apple ID is given.
APP_ID=()
[ "$TARGET" = catalyst-arm64 ] && APP_ID=(--apple-id "${ASC_APPLE_ID:-6779847344}")
xcrun altool "$action" "$PACKAGE" ${APP_ID[@]+"${APP_ID[@]}"} \
  --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"
if [ "${VALIDATE_ONLY:-}" = "1" ]; then
  echo "Validated build $BUILD_NUMBER; not uploaded."
  exit 0
fi
echo
echo "Uploaded build $BUILD_NUMBER. It appears in App Store Connect →"
echo "TestFlight after ~5-30 min of processing. Then add testers and (for"
echo "external testers) submit the first build for the quick beta review."
