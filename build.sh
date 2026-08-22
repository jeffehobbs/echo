#!/bin/zsh
# Build Echo.
#   ./build.sh            Debug build
#   ./build.sh run        Debug build, then launch
#   ./build.sh release    Release → Developer ID sign → verify
#   ./build.sh notarize   release → notarize → staple → dist/Echo-<ver>.zip
#
# Notarizing needs a one-time stored credential profile (Apple ID method):
#   xcrun notarytool store-credentials echo-notary \
#     --apple-id "you@example.com" --team-id YKF353373Y \
#     --password "<app-specific-password>"
# The credential is per Apple ID rather than per app, so a profile already
# stored for another app works too; the script uses the first that
# authenticates. Set NOTARY_PROFILE=... to force one.
#
# Echo is signed with the hardened runtime and no entitlements, and is
# deliberately not sandboxed. It needs neither: it opens CoreMIDI endpoints and
# an audio output unit — neither is a restricted resource — and its only
# persisted state is UserDefaults. The sandbox would buy nothing for Developer
# ID distribution and gets in the way of talking to a class-compliant USB
# controller.
set -e
cd "$(dirname "$0")"

MODE="${1:-debug}"
DEV_ID="${DEV_ID:-Developer ID Application}"   # codesign matches this as a substring
TEAM_ID=YKF353373Y

CONFIG=Debug
[[ "$MODE" == "release" || "$MODE" == "notarize" ]] && CONFIG=Release

xcodegen generate --quiet
xcodebuild -project Echo.xcodeproj -scheme Echo -configuration "$CONFIG" \
  -derivedDataPath build -quiet build

APP="build/Build/Products/$CONFIG/Echo.app"
echo "Built: $APP"

# First stored notary credential that authenticates wins.
resolve_notary_profile() {
  local candidates=(echo-notary thrum-notary mutiny-notary)
  [[ -n "$NOTARY_PROFILE" ]] && candidates=("$NOTARY_PROFILE")
  local p
  for p in $candidates; do
    if xcrun notarytool history --keychain-profile "$p" >/dev/null 2>&1; then
      echo "$p"; return 0
    fi
  done
  echo "✗ No usable notarytool credential profile (tried: $candidates)." >&2
  echo "  Create one with: xcrun notarytool store-credentials echo-notary \\" >&2
  echo "    --apple-id \"you@example.com\" --team-id $TEAM_ID --password \"<app-specific-password>\"" >&2
  return 1
}

if [[ "$MODE" == "debug" || "$MODE" == "run" ]]; then
  # Refresh the installed copy so the Dock and LaunchServices see a stable app.
  if [[ -d "$HOME/Applications/Echo.app" ]]; then
    osascript -e 'quit app "Echo"' 2>/dev/null || true
    sleep 1
    ditto "$APP" "$HOME/Applications/Echo.app"
    echo "Installed: ~/Applications/Echo.app"
  fi
  if [[ "$MODE" == "run" ]]; then
    osascript -e 'quit app "Echo"' 2>/dev/null || true
    sleep 1
    open "$APP"
  fi
  exit 0
fi

# --- Developer ID signing -----------------------------------------------------
#
# Xcode has already signed the bundle for local running; this re-signs it with
# the Developer ID identity and the hardened runtime, which is what Gatekeeper
# on someone else's Mac cares about. Echo embeds no frameworks or helpers, so
# one call covers the whole bundle.
echo "--- signing with \"$DEV_ID\" ---"
codesign --force --timestamp --options runtime --sign "$DEV_ID" "$APP"

echo "--- verifying ---"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier|Timestamp|Signature|Runtime)" || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

if [[ "$MODE" == "release" ]]; then
  # An unnotarized Developer ID build fails `spctl` until it is notarized. That
  # is expected here, so report it rather than failing the build.
  spctl --assess --type execute --verbose=2 "$APP" 2>&1 || \
    echo "  (not notarized yet — run ./build.sh notarize)"
  echo "Signed Echo $VERSION"
  exit 0
fi

# --- Notarize -----------------------------------------------------------------
PROFILE=$(resolve_notary_profile)
mkdir -p dist
ZIP="dist/Echo-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the bundle's symlinks and extended attributes intact; `zip` does not.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "--- notarizing $ZIP (profile: $PROFILE) ---"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "--- stapling ---"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Re-zip so the distributed archive carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarized and stapled: $ZIP"
