#!/usr/bin/env bash
# Build Snapline.app into build/Snapline.app.
#
#   bash Scripts/build.sh
#
# The Xcode project is generated from project.yml, so this script owns the whole
# chain: icon -> xcodegen -> xcodebuild -> codesign. Both CI and the release
# pipeline run this exact script, so a green CI run means the release build works.
#
# Signing is done here by hand rather than by xcodebuild (which is invoked with
# CODE_SIGNING_ALLOWED=NO) for one reason: the same script then works on a runner
# with no certificate in the keychain as on a machine with a Developer ID. Pick
# the mode with SNAPLINE_SIGNING_IDENTITY:
#
#   "Developer ID Application"   hardened runtime + secure Apple timestamp +
#     (or the full                entitlements — the exact combination Apple's
#      "Developer ID              notary service requires. Signing failures are
#      Application: NAME (TEAM)") FATAL. This is what the release workflow uses.
#
#   "-"                          ad-hoc. Fine for a compile + bundle check on CI.
#                                Never notarizable, and macOS re-asks for the
#                                Screen Recording grant on every rebuild.
#
# Unset, the script picks Developer ID when that certificate is installed and
# falls back to ad-hoc when it is not — so a local build stays notarization-shaped
# and keeps its Screen Recording grant across rebuilds, and CI still passes.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Snapline"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-build}"
APP_DIR="build/${APP_NAME}.app"

# One entitlement: com.apple.security.device.audio-input. Under the hardened runtime,
# ScreenCaptureKit's microphone capture (macOS 15+) is refused without it, silently, so
# a recording would come out with no voice track. Screen capture itself is gated on the
# Screen Recording grant in System Settings (TCC), not on an entitlement. The App Sandbox
# is not enabled: Snapline writes captures to a folder the user picks and hands dragged
# files to any app. The file must carry no XML comments: Apple's AMFI parser rejects
# them ("AMFIUnserializeXML: syntax error").
ENTITLEMENTS="${APP_NAME}.entitlements"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "ERROR: xcodegen not found. Install it with: brew install xcodegen" >&2
    exit 1
fi

if [[ ! -f "Resources/AppIcon.icns" ]]; then
    echo "==> Resources/AppIcon.icns missing, rendering it"
    swift Scripts/make_icon.swift
fi

echo "==> xcodegen generate"
xcodegen generate --quiet

# Release builds are universal. Both the CI runner and this Mac are arm64, and a
# native-only build simply refuses to launch on an Intel Mac — which macOS 14 still
# supports, so an arm64-only DMG would be broken for a slice of the people who
# download it. UNIVERSAL=0 skips the second slice for a faster local iteration build.
# Expanded as ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} below: under `set -u`, bash 3.2 — which
# is what /bin/bash still is on macOS — treats "${empty[@]}" as an unbound variable.
ARCH_ARGS=()
if [[ "${UNIVERSAL:-1}" == "1" ]]; then
    ARCH_ARGS=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
fi

echo "==> xcodebuild ($CONFIGURATION, unsigned — signed below)"
xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${APP_NAME}" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    build

BUILT="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
if [[ ! -d "$BUILT" ]]; then
    echo "ERROR: xcodebuild reported success but there is no bundle at $BUILT" >&2
    exit 1
fi

echo "==> staging ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p build
cp -R "$BUILT" "$APP_DIR"
# Quarantine and resource-fork xattrs make codesign fail on some machines.
xattr -cr "$APP_DIR" 2>/dev/null || true

# Sparkle arrives from Swift Package Manager ad-hoc signed. Under the hardened runtime,
# library validation refuses to load a framework that is not signed by the same team as
# the app, and the notary service rejects any nested code without a Developer ID and a
# secure timestamp. So every piece of it is signed again here, innermost first, with the
# same identity as the app — `--deep` is not used because it signs in the wrong order.
#
# The two XPC services are dropped first. Sparkle only uses them for a sandboxed app,
# which Snapline is not (see ENTITLEMENTS above), and code that is not shipped is code
# that never needs signing.
SPARKLE="${APP_DIR}/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
fi

sign_sparkle() {
    [[ -d "$SPARKLE" ]] || return 0
    local flags=("$@")
    codesign "${flags[@]}" "$SPARKLE/Versions/B/Autoupdate"
    codesign "${flags[@]}" "$SPARKLE/Versions/B/Updater.app"
    codesign "${flags[@]}" "$SPARKLE"
}

have_developer_id() {
    security find-identity -v -p codesigning 2>/dev/null |
        grep -q "Developer ID Application"
}

SIGNING_IDENTITY="${SNAPLINE_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    if have_developer_id; then
        SIGNING_IDENTITY="Developer ID Application"
    else
        SIGNING_IDENTITY="-"
        echo "==> No Developer ID certificate in the keychain — falling back to ad-hoc signing."
        echo "    For a distributable build, install the certificate or set"
        echo "    SNAPLINE_SIGNING_IDENTITY='Developer ID Application'."
    fi
fi

case "$SIGNING_IDENTITY" in
  "Developer ID"*)
    if ! have_developer_id; then
        echo "ERROR: release signing requested ('$SIGNING_IDENTITY') but no 'Developer ID" >&2
        echo "       Application' certificate is installed. See Scripts/notarize.sh header." >&2
        exit 1
    fi
    echo "==> Signing with '$SIGNING_IDENTITY' (hardened runtime + secure timestamp, notarization-ready)"
    sign_sparkle --force --options runtime --timestamp --sign "$SIGNING_IDENTITY"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" "$APP_DIR"
    codesign --verify --strict --verbose=2 "$APP_DIR"
    ;;
  *)
    echo "==> Ad-hoc signing (compile check only — not distributable)"
    sign_sparkle --force --sign -
    codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP_DIR"
    ;;
esac

echo "==> Built $APP_DIR"
lipo -archs "${APP_DIR}/Contents/MacOS/${APP_NAME}" 2>/dev/null |
    sed 's/^/    architectures: /'
echo "    Install with: cp -R $APP_DIR /Applications/"
