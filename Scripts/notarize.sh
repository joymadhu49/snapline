#!/usr/bin/env bash
# Notarize + staple a DMG (or .app) with Apple's notary service, then verify it.
#
# Run it twice, which is what the release workflow does:
#
#   bash Scripts/notarize.sh build/Snapline.app     # after build.sh, before make-dmg.sh
#   bash Scripts/notarize.sh                        # after make-dmg.sh, on the DMG
#
# Notarizing the DMG alone is enough for the download to open cleanly, but the
# app dragged out of it then carries no ticket of its own, so Gatekeeper has to
# ask Apple over the network the first time it runs. Stapling the app too — and
# building the DMG from the already-stapled app — makes the copy in
# /Applications verify offline. `xcrun stapler validate` on the .app is the
# check for this; it reports "does not have a ticket stapled to it" otherwise.
#
# ── Authentication (App Store Connect API key) ───────────────────────────────
# Provide ONE of:
#
#   A) A stored notarytool keychain profile (best for repeated LOCAL runs):
#        xcrun notarytool store-credentials snapline-notary \
#          --key    /path/AuthKey_XXXXXX.p8 \
#          --key-id <KEY_ID> \
#          --issuer <ISSUER_ID>
#        AC_KEYCHAIN_PROFILE=snapline-notary bash Scripts/notarize.sh
#
#   B) The three API-key values directly (best for CI):
#        AC_API_KEY_ID=<KEY_ID>
#        AC_API_ISSUER_ID=<ISSUER_ID>
#        AC_API_KEY_P8=<base64 of the .p8>   # or AC_API_KEY_P8_PATH=/path/AuthKey.p8
#
# Get these from App Store Connect → Users and Access → Integrations → Keys,
# with key role "Developer" or higher. The .p8 downloads exactly once.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-$(ls -t build/Snapline-*.dmg 2>/dev/null | head -1 || true)}"
if [[ -z "${TARGET:-}" || ! -e "$TARGET" ]]; then
    echo "ERROR: notarize target not found (got: '${TARGET:-<none>}'). Run Scripts/make-dmg.sh first." >&2
    exit 1
fi

# notarytool only accepts .zip, .dmg and .pkg, so an .app has to be zipped for
# the submission. The ticket still staples to the .app itself afterwards.
SUBMIT_TARGET="$TARGET"
ZIP_TO_CLEAN=""
if [[ "$TARGET" == *.app ]]; then
    SUBMIT_TARGET="$(mktemp -d)/$(basename "${TARGET%.app}").zip"
    # ditto -c -k --keepParent is the archive format notarytool expects; `zip -r`
    # mangles the symlinks and extended attributes inside a bundle.
    ditto -c -k --keepParent "$TARGET" "$SUBMIT_TARGET"
    ZIP_TO_CLEAN="$SUBMIT_TARGET"
fi

echo "==> Notarizing $TARGET"
submit_args=(--wait)

if [[ -n "${AC_KEYCHAIN_PROFILE:-}" ]]; then
    submit_args+=(--keychain-profile "$AC_KEYCHAIN_PROFILE")
else
    : "${AC_API_KEY_ID:?set AC_API_KEY_ID (or AC_KEYCHAIN_PROFILE)}"
    : "${AC_API_ISSUER_ID:?set AC_API_ISSUER_ID (or AC_KEYCHAIN_PROFILE)}"
    KEY_PATH="${AC_API_KEY_P8_PATH:-}"
    if [[ -z "$KEY_PATH" && -n "${AC_API_KEY_P8:-}" ]]; then
        KEY_PATH="$(mktemp -t ac_api_key_XXXXXX).p8"
        # shellcheck disable=SC2064
        trap "rm -f '$KEY_PATH'" EXIT
        printf '%s' "$AC_API_KEY_P8" | base64 --decode > "$KEY_PATH"
    fi
    if [[ -z "$KEY_PATH" || ! -f "$KEY_PATH" ]]; then
        echo "ERROR: provide AC_API_KEY_P8_PATH or AC_API_KEY_P8 (base64), or AC_KEYCHAIN_PROFILE." >&2
        exit 1
    fi
    submit_args+=(--key "$KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID")
fi

# --wait blocks until Apple finishes; a non-"Accepted" status exits non-zero.
xcrun notarytool submit "$SUBMIT_TARGET" "${submit_args[@]}"
[[ -n "$ZIP_TO_CLEAN" ]] && rm -f "$ZIP_TO_CLEAN"

echo "==> Stapling notarization ticket"
xcrun stapler staple "$TARGET"

echo "==> Verifying"
xcrun stapler validate "$TARGET"
if [[ "$TARGET" == *.app ]]; then
    # The real question for an .app: what Gatekeeper does when someone launches
    # the copy in /Applications. Wants "source=Notarized Developer ID".
    spctl -a -vvv -t exec "$TARGET" 2>&1
else
    # A DMG is not itself signed, so `spctl -t open` reports "no usable
    # signature" even when the ticket is present and valid. Best-effort only;
    # `stapler validate` above is the authoritative gate.
    spctl -a -vvv -t open --context context:primary-signature "$TARGET" 2>&1 || true
fi

echo "==> Done. Notarized + stapled: $TARGET"
