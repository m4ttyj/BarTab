#!/bin/bash
# Builds "BarTab.app" from the Swift package.
#
#   ./scripts/build-app.sh                    release build into ./build, ad-hoc signed
#   ./scripts/build-app.sh --debug            faster build, no optimisation
#   ./scripts/build-app.sh --universal        arm64 + x86_64
#   ./scripts/build-app.sh --install          also copy the result into /Applications
#   ./scripts/build-app.sh --run              launch it when the build finishes
#
# Distribution (see "One-time setup" below):
#   ./scripts/build-app.sh --sign             sign with your Developer ID, hardened runtime
#   ./scripts/build-app.sh --sign="Developer ID Application: You (TEAMID)"
#   ./scripts/build-app.sh --notarize         sign, notarize, staple, and zip for release
#   ./scripts/build-app.sh --notarize=profile use a specific notarytool keychain profile
#
# BARTAB_SIGN_IDENTITY and BARTAB_NOTARY_PROFILE work as defaults for the two above.
#
# One-time setup for --notarize:
#   1. Create a "Developer ID Application" certificate at
#      https://developer.apple.com/account/resources/certificates and install it.
#      (An "Apple Distribution" certificate is for the App Store and will NOT work.)
#   2. Store notary credentials in the keychain once:
#        xcrun notarytool store-credentials "bartab-notary" \
#          --key ~/private_keys/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer <issuer-uuid>
#      or, with an app-specific password instead of an API key:
#        xcrun notarytool store-credentials "bartab-notary" \
#          --apple-id "you@example.com" --team-id "TEAMID" --password "abcd-efgh-ijkl-mnop"
#
# Note: BarTab is deliberately not sandboxed — it has to exec brew and read the
# Homebrew prefix — so it cannot go to the Mac App Store. Developer ID signing
# plus notarization is the supported route, and the hardened runtime used here
# does not interfere with launching brew as a subprocess.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="BarTab"
BUNDLE_ID="co.damtech.bartab"
VERSION="1.3"
BUILD_NUMBER="4"
MIN_MACOS="14.0"

CONFIG="release"
ARCH_FLAGS=()
DO_INSTALL=0
DO_RUN=0
DO_SIGN=0
DO_NOTARIZE=0
SIGN_IDENTITY="${BARTAB_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${BARTAB_NOTARY_PROFILE:-bartab-notary}"

for arg in "$@"; do
  case "$arg" in
    --debug)      CONFIG="debug" ;;
    --release)    CONFIG="release" ;;
    --universal)  ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
    --install)    DO_INSTALL=1 ;;
    --run)        DO_RUN=1 ;;
    --sign)       DO_SIGN=1 ;;
    --sign=*)     DO_SIGN=1; SIGN_IDENTITY="${arg#*=}" ;;
    --notarize)   DO_SIGN=1; DO_NOTARIZE=1 ;;
    --notarize=*) DO_SIGN=1; DO_NOTARIZE=1; NOTARY_PROFILE="${arg#*=}" ;;
    -h|--help)    sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight. Everything that can be checked without building is checked first,
# so a missing certificate fails in a second rather than after a full build.
# ---------------------------------------------------------------------------

if [ "$DO_SIGN" = "1" ] && [ -z "$SIGN_IDENTITY" ]; then
  echo "==> Looking for a Developer ID Application certificate"
  MATCHES="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' || true)"
  COUNT="$(printf '%s' "$MATCHES" | grep -c 'Developer ID Application' || true)"

  if [ "${COUNT:-0}" -eq 0 ]; then
    cat >&2 <<MSG
No "Developer ID Application" certificate is installed.

Identities currently in your keychain:
$(security find-identity -v -p codesigning 2>/dev/null | sed 's/^/  /' || echo "  (none)")

An "Apple Development" certificate only signs for local use, and an "Apple
Distribution" certificate is for the App Store — neither can be notarized for
distribution outside it. Create a Developer ID Application certificate at
  https://developer.apple.com/account/resources/certificates
then download and double-click it to install, and run this again.

Or name one explicitly:
  ./scripts/build-app.sh --sign="Developer ID Application: Your Name (TEAMID)"
MSG
    exit 1
  fi

  if [ "$COUNT" -gt 1 ]; then
    cat >&2 <<MSG
More than one Developer ID Application certificate found. Pick one:
$(printf '%s\n' "$MATCHES" | sed -E 's/.*"(.*)".*/  --sign="\1"/')
MSG
    exit 1
  fi

  SIGN_IDENTITY="$(printf '%s\n' "$MATCHES" | sed -E 's/.*"(.*)".*/\1/')"
  echo "    $SIGN_IDENTITY"
fi

if [ "$DO_NOTARIZE" = "1" ]; then
  echo "==> Checking notary credentials (keychain profile: $NOTARY_PROFILE)"
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<MSG
Couldn't authenticate with the notary service using keychain profile
"$NOTARY_PROFILE". Either the profile doesn't exist, its credentials have
expired, or you're offline.

Store it once with an App Store Connect API key:
  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
    --key ~/private_keys/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer <issuer-uuid>

Or with an app-specific password from appleid.apple.com:
  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
    --apple-id "you@example.com" --team-id "TEAMID" --password "abcd-efgh-ijkl-mnop"
MSG
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Build and assemble
# ---------------------------------------------------------------------------

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BINARY="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/BarTab"
[ -x "$BINARY" ] || { echo "Build produced no binary at $BINARY" >&2; exit 1; }

APP="$ROOT/build/$APP_NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/BarTab"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>       <string>en</string>
    <key>CFBundleExecutable</key>              <string>BarTab</string>
    <key>CFBundleIconFile</key>                <string>AppIcon</string>
    <key>CFBundleIdentifier</key>              <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>   <string>6.0</string>
    <key>CFBundleName</key>                    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>             <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>             <string>APPL</string>
    <key>CFBundleShortVersionString</key>      <string>$VERSION</string>
    <key>CFBundleVersion</key>                 <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>          <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key>       <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>         <true/>
    <key>NSHumanReadableCopyright</key>        <string>© 2026 Matthew Jarrett. MIT licensed. Not affiliated with the Homebrew project.</string>
    <key>NSPrincipalClass</key>                <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>  <true/>
    <key>NSSupportsSuddenTermination</key>     <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------------------------------------------------------------------------
# Sign. There is no nested code in the bundle, so --deep is neither needed nor
# wanted (Apple advises against it for signing). No entitlements file either:
# the app needs no special capabilities, and it must NOT be sandboxed.
# ---------------------------------------------------------------------------

if [ "$DO_SIGN" = "1" ]; then
  echo "==> Signing with Developer ID (hardened runtime)"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  # Ad-hoc: enough to launch on this Mac, rejected by Gatekeeper anywhere else.
  # The hardened runtime is applied here too, so a local build behaves exactly
  # like a signed release one and any runtime restriction surfaces now rather
  # than at notarization time.
  echo "==> Signing (ad-hoc, hardened runtime, local use only)"
  codesign --force --sign - --options runtime --timestamp=none "$APP" >/dev/null 2>&1 \
    || echo "    (codesign failed; the app will still run but Gatekeeper may complain)"
fi

touch "$APP"
echo "==> Built $APP"

# ---------------------------------------------------------------------------
# Notarize, staple, and produce the artifact to ship.
# ---------------------------------------------------------------------------

if [ "$DO_NOTARIZE" = "1" ]; then
  SUBMIT_ZIP="$ROOT/build/$APP_NAME-submit.zip"
  echo "==> Submitting to the notary service (this usually takes a few minutes)"
  # ditto, not zip: it preserves the bundle's symlinks and metadata.
  rm -f "$SUBMIT_ZIP"
  ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

  set +e
  NOTARY_OUT="$(xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  NOTARY_STATUS=$?
  set -e
  printf '%s\n' "$NOTARY_OUT" | sed 's/^/    /'
  rm -f "$SUBMIT_ZIP"

  SUBMISSION_ID="$(printf '%s\n' "$NOTARY_OUT" | awk '/^ *id: / { print $2; exit }')"

  if [ "$NOTARY_STATUS" -ne 0 ] || ! printf '%s\n' "$NOTARY_OUT" | grep -q "status: Accepted"; then
    echo "==> Notarization did not succeed" >&2
    if [ -n "$SUBMISSION_ID" ]; then
      echo "    Fetching the notary log for $SUBMISSION_ID:" >&2
      xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | sed 's/^/    /' >&2 || true
    fi
    exit 1
  fi

  echo "==> Stapling the ticket"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"

  # `-t install` is the assessment that actually reports notarization state: it
  # returns "Unnotarized Developer ID" for a signed-but-unnotarized bundle.
  # `-t exec` only checks the signature and would say "accepted" regardless,
  # which makes it useless as a check that notarization worked.
  echo "==> Gatekeeper assessment"
  spctl -a -vv -t install "$APP" 2>&1 | sed 's/^/    /'

  # Re-zip only now: the ticket lives inside the bundle, so an archive made
  # before stapling would ship unnotarized.
  DIST_ZIP="$ROOT/build/$APP_NAME-$VERSION.zip"
  rm -f "$DIST_ZIP"
  ditto -c -k --keepParent "$APP" "$DIST_ZIP"
  echo "==> Ready to distribute: $DIST_ZIP"
fi

if [ "$DO_INSTALL" = "1" ]; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  # ditto rather than cp -R so signature and ticket metadata survive the copy.
  ditto "$APP" "/Applications/$APP_NAME.app"
  APP="/Applications/$APP_NAME.app"
fi

if [ "$DO_RUN" = "1" ]; then
  echo "==> Launching"
  open "$APP"
fi
