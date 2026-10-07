#!/usr/bin/env bash
# Sign a notarized DMG for Sparkle and write build/appcast.xml describing it.
#
#   bash Scripts/make-appcast.sh                        # newest build/Snapline-*.dmg
#   bash Scripts/make-appcast.sh build/Snapline-1.1.0.dmg
#
# Run AFTER Scripts/notarize.sh on the DMG: the signature covers the exact bytes users
# download, and stapling rewrites the DMG, so signing earlier would sign the wrong file.
#
# The appcast is attached to the GitHub release next to the DMG. The app's SUFeedURL
# points at releases/latest/download/appcast.xml, which GitHub redirects to whichever
# release is newest — so publishing a release is what publishes the update, and there
# is no second place to keep in step.
#
# ── The EdDSA private key ────────────────────────────────────────────────────
# Provide ONE of:
#   SPARKLE_ED_PRIVATE_KEY   the key itself (CI: the repository secret of that name)
#   nothing                  sign_update reads it from the login keychain, where
#                            Sparkle's generate_keys stored it on the maintainer's Mac
#
# Its public half is SUPublicEDKey in project.yml. Lose the private key and every
# installed copy stops accepting updates, so keep the keychain item backed up
# (generate_keys -x exports it).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Snapline"
REPO="joymadhu49/snapline"
APP="build/${APP_NAME}.app"

DMG="${1:-$(ls -t build/${APP_NAME}-*.dmg 2>/dev/null | head -1 || true)}"
if [[ -z "${DMG:-}" || ! -f "$DMG" ]]; then
    echo "ERROR: DMG not found (got: '${DMG:-<none>}'). Run Scripts/make-dmg.sh first." >&2
    exit 1
fi

# The tools come with the Sparkle package xcodebuild already resolved, so they are the
# same version as the framework inside the app.
SIGN_UPDATE="$(find build/SourcePackages/artifacts -path '*/bin/sign_update' -not -path '*old_dsa*' 2>/dev/null | head -1)"
if [[ -z "$SIGN_UPDATE" ]]; then
    echo "ERROR: Sparkle's sign_update not found under build/SourcePackages. Run Scripts/build.sh first." >&2
    exit 1
fi

PLIST="${APP}/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
TAG="v${SHORT_VERSION}"
DMG_NAME="$(basename "$DMG")"

if [[ "$DMG_NAME" != "${APP_NAME}-${SHORT_VERSION}.dmg" ]]; then
    echo "ERROR: $DMG_NAME does not match the built app's version ${SHORT_VERSION}." >&2
    exit 1
fi

echo "==> Signing $DMG_NAME for Sparkle"
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    ENCLOSURE_ATTRS="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG")"
else
    ENCLOSURE_ATTRS="$("$SIGN_UPDATE" "$DMG")"
fi
# sign_update prints: sparkle:edSignature="..." length="..."
if [[ "$ENCLOSURE_ATTRS" != *'sparkle:edSignature="'* ]]; then
    echo "ERROR: sign_update did not return a signature: $ENCLOSURE_ATTRS" >&2
    exit 1
fi

OUT="build/appcast.xml"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>${APP_NAME}</title>
    <link>https://github.com/${REPO}</link>
    <item>
      <title>Version ${SHORT_VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/${REPO}/releases/tag/${TAG}</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/${REPO}/releases/download/${TAG}/${DMG_NAME}"
                 type="application/octet-stream"
                 ${ENCLOSURE_ATTRS} />
    </item>
  </channel>
</rss>
XML

xmllint --noout "$OUT"
echo "==> Wrote $OUT for ${TAG}"
