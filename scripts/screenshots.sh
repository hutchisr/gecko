#!/usr/bin/env bash
# Website screenshots of the iPhone and Mac apps, light and dark, from the
# DEBUG `showcase` fixture in App/Model.swift: no account, core or network.
# Output: build/screenshots/{ios,mac}/<screen>-<light|dark>.png
#
# Usage: scripts/screenshots.sh [ios|mac|all]
#   GECKO_SHOTS_SIM=<udid>  Simulator to use (default: the one named "Gecko Shots iPhone")
# Needs build/prefix/sim-arm64 and/or catalyst-arm64 (scripts/build-deps.sh), and
# Screen Recording permission for the terminal (Mac window capture).
set -euo pipefail
WHAT="${1:-all}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DD="$REPO/build/shots"
OUT="${GECKO_SHOTS_OUT:-$REPO/build/screenshots}"
BUNDLE=me.anemoneya.gecko
# screen name -> conversation to open ("" = conversation list)
SCREENS=("list:" "chat:tokay@example.org" "group:basking-rock@conference.example.org")
# The chat photo: "Snowy mountain reflection (Unsplash).jpg", CC0, Wikimedia Commons.
PHOTO="$DD/lake.jpg"
mkdir -p "$DD"
[ -s "$PHOTO" ] || curl -fsSL -A 'Gecko screenshots' -o "$PHOTO" \
  'https://commons.wikimedia.org/wiki/Special:FilePath/Snowy_mountain_reflection_(Unsplash).jpg?width=1600'

build() {  # $1 = xcodebuild destination, rest = extra settings
  local dest="$1"; shift
  xcodebuild -project "$REPO/Gecko.xcodeproj" -scheme Gecko -configuration Debug \
    -destination "$dest" -derivedDataPath "$DD/$WHICH-dd" "$@" build -quiet
}

ios() {
  WHICH=sim
  local sim="${GECKO_SHOTS_SIM:-$(xcrun simctl list devices available | awk -F'[()]' '/Gecko Shots iPhone/ {print $2; exit}')}"
  [ -n "$sim" ] || { echo "error: no Simulator named 'Gecko Shots iPhone'; set GECKO_SHOTS_SIM" >&2; exit 1; }
  build "platform=iOS Simulator,id=$sim"
  xcrun simctl boot "$sim" 2>/dev/null || true
  xcrun simctl bootstatus "$sim" -b >/dev/null
  xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl install "$sim" "$DD/sim-dd/Build/Products/Debug-iphonesimulator/Gecko.app"
  mkdir -p "$OUT/ios"
  for look in light dark; do
    xcrun simctl ui "$sim" appearance "$look"
    for s in "${SCREENS[@]}"; do
      SIMCTL_CHILD_DINO_UI_TEST_FIXTURE=showcase SIMCTL_CHILD_DINO_SHOWCASE_PHOTO="$PHOTO" \
        SIMCTL_CHILD_DINO_UI_TEST_OPEN_JID="${s#*:}" \
        xcrun simctl launch --terminate-running-process "$sim" "$BUNDLE" >/dev/null
      sleep 4   # image decode and the opening scroll settle
      xcrun simctl io "$sim" screenshot "$OUT/ios/${s%%:*}-$look.png" 2>/dev/null
    done
  done
  xcrun simctl terminate "$sim" "$BUNDLE" || true
  xcrun simctl ui "$sim" appearance light
  xcrun simctl status_bar "$sim" clear
}

mac() {
  WHICH=mac
  build 'platform=macOS,variant=Mac Catalyst,arch=arm64' CODE_SIGNING_ALLOWED=NO
  local app="$DD/mac-dd/Build/Products/Debug-maccatalyst/Gecko.app"
  codesign --force --sign - "$app/Contents/Frameworks/WebRTC.framework"
  codesign --force --sign - --deep "$app"
  mkdir -p "$OUT/mac"
  # Catalyst ignores -AppleInterfaceStyle, so dark shots flip the system
  # appearance for a few seconds and the trap puts it back.
  local was_dark; was_dark="$(osascript -e 'tell application "System Events" to get dark mode of appearance preferences')"
  trap "osascript -e 'tell application \"System Events\" to set dark mode of appearance preferences to $was_dark'" EXIT
  for look in light dark; do
    osascript -e "tell application \"System Events\" to set dark mode of appearance preferences to $([ "$look" = dark ] && echo true || echo false)"
    for s in "${SCREENS[@]}"; do
      # The sidebar already shows the list; the empty detail pane is no shot.
      [ "${s%%:*}" = list ] && continue
      # -n: a second instance beside any installed Gecko; the fixture never
      # starts the core, so it does not touch that one's account or store.
      open -n -F --env DINO_UI_TEST_FIXTURE=showcase --env "DINO_SHOWCASE_PHOTO=$PHOTO" \
        --env "DINO_UI_TEST_OPEN_JID=${s#*:}" "$app"
      sleep 5
      local pid; pid="$(pgrep -n -f "$app/Contents/MacOS/Gecko")"
      # The first launch after a build can take longer to show its window.
      local try
      for try in 1 2 3 4 5; do
        osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid)
          set position of front window to {80, 80}
          set size of front window to {1280, 800}
        end tell" >/dev/null 2>&1 && break
        [ "$try" = 5 ] && echo "note: could not resize the window (Accessibility permission?)" >&2
        sleep 1
      done
      sleep 2
      local wid; wid="$(swift "$REPO/scripts/window-id.swift" "$pid")"
      screencapture -o -l "$wid" "$OUT/mac/${s%%:*}-$look.png"
      kill "$pid"
    done
  done
}

case "$WHAT" in
  ios) ios ;;
  mac) mac ;;
  all) ios; mac ;;
  *) echo "usage: $0 [ios|mac|all]" >&2; exit 2 ;;
esac
echo "screenshots in $OUT"
