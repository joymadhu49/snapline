#!/usr/bin/env bash
# Package build/Snapline.app into a distributable build/Snapline-<version>.dmg.
#
#   bash Scripts/make-dmg.sh            # version read from the built Info.plist
#   bash Scripts/make-dmg.sh 1.0.1      # or state it
#
# Run AFTER Scripts/build.sh, then Scripts/notarize.sh on the result.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Snapline"
APP="build/${APP_NAME}.app"

if [[ ! -d "$APP" ]]; then
    echo "App bundle not found at $APP — running Scripts/build.sh first..."
    bash Scripts/build.sh
fi

DEFAULT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${APP}/Contents/Info.plist" 2>/dev/null || echo 1.0.0)"
VERSION="${1:-$DEFAULT_VERSION}"
DMG="build/${APP_NAME}-${VERSION}.dmg"

rm -f "$DMG"
echo "==> creating $DMG"

# Preferred: a styled installer window with positioned icons and a volume icon,
# via create-dmg (`brew install create-dmg`). 560x400 pt window, app on the left,
# the Applications drop link on the right.
styled_dmg() {
    command -v create-dmg >/dev/null 2>&1 || return 1
    local stage
    stage="$(mktemp -d)/styled"
    mkdir -p "$stage"
    cp -R "$APP" "$stage/"
    local args=(
        --volname "$APP_NAME"
        --window-pos 200 120
        --window-size 560 400
        --icon-size 112
        --text-size 13
        --icon "${APP_NAME}.app" 150 190
        --app-drop-link 410 190
        --hide-extension "${APP_NAME}.app"
        --no-internet-enable
    )
    [[ -f "Resources/AppIcon.icns" ]] && args+=(--volicon "Resources/AppIcon.icns")
    create-dmg "${args[@]}" "$DMG" "$stage"
}

# Fallback: a plain DMG via hdiutil. Always works, including where create-dmg is
# missing or Finder scripting is unavailable on a CI runner.
plain_dmg() {
    local stage
    stage="$(mktemp -d)/${APP_NAME}"
    mkdir -p "$stage"
    cp -R "$APP" "$stage/"
    ln -s /Applications "$stage/Applications"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$stage" \
        -ov \
        -format UDZO \
        -fs HFS+ \
        "$DMG" >/dev/null
}

if styled_dmg; then
    echo "==> styled DMG (create-dmg)"
else
    echo "==> create-dmg unavailable or failed — falling back to plain hdiutil DMG"
    rm -f "$DMG" rw.*.dmg 2>/dev/null || true
    plain_dmg
fi

ls -lh "$DMG"
echo "==> Done: $DMG"
