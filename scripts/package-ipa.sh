#!/usr/bin/env bash
#
# package-ipa.sh — wrap a built .app into a .ipa.
#
# The result is deliberately unsigned. An .ipa is just a zip whose root contains a
# `Payload` directory holding the app bundle; signing is a separate concern, and
# the signer has to be the person with the certificate. Sideloadly, AltStore and
# Xcode all accept this file and re-sign it, which is why building without a
# certificate is a supported workflow rather than a hack.
#
# Usage: scripts/package-ipa.sh <path/to/App.app> [output.ipa]
#
set -euo pipefail

APP="${1:-}"
OUTPUT="${2:-dist/EarthboundWrapper.ipa}"

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "usage: $0 <path/to/App.app> [output.ipa]" >&2
  echo "       (no app bundle at '${APP:-<unset>}')" >&2
  exit 1
fi

APP_NAME="$(basename "$APP" .app)"
BINARY="$APP/$APP_NAME"
if [ ! -f "$BINARY" ]; then
  echo "error: $APP does not contain an executable named $APP_NAME" >&2
  echo "       an app bundle without its binary packages into an .ipa that installs" >&2
  echo "       and then immediately fails to launch" >&2
  exit 1
fi

echo "==> packaging $APP_NAME"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$STAGING/Payload"
# ditto rather than cp -R: an app bundle contains symlinks and extended
# attributes, and a packaging step that quietly dereferences a framework symlink
# produces a bundle that is subtly a different shape from the one that was built.
ditto "$APP" "$STAGING/Payload/$APP_NAME.app"

# A build made with CODE_SIGNING_ALLOWED=NO has no signature, but a build from
# Xcode might. Leaving a stale signature or provisioning profile inside an .ipa
# that is about to be re-signed is what produces the baffling
# "application-identifier entitlement not found" install failure.
rm -rf "$STAGING/Payload/$APP_NAME.app/_CodeSignature"
rm -f "$STAGING/Payload/$APP_NAME.app/embedded.mobileprovision"

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
ditto -c -k --sequesterRsrc --keepParent "$STAGING/Payload" "$OUTPUT"

SIZE="$(du -h "$OUTPUT" | cut -f1)"
echo "==> $OUTPUT ($SIZE)"
echo "    sha256 $(shasum -a 256 "$OUTPUT" | cut -d' ' -f1)"

# The core is linked in, not shipped alongside, so this is a sanity check that the
# build actually contained emulation rather than just the UI.
if strings "$BINARY" | grep -q "snes9x"; then
  echo "    core: snes9x symbols present"
else
  echo "    warning: no snes9x symbols found in the binary — was the core linked?" >&2
fi
