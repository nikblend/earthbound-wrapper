#!/usr/bin/env bash
#
# verify-core-pin.sh — check that the vendored libretro.h is the one that belongs
# to the pinned core revision.
#
# The header is what the whole Swift side is written against: LibretroConstants
# mirrors its command numbers, and EBCoreGlue.c static-asserts them. If the
# revision marker moves without the header moving with it, the asserts still pass
# (they check the header, not the core) and the failure surfaces later as a core
# that ignores an option or refuses to load.
#
#   scripts/verify-core-pin.sh      # check
#   scripts/verify-core-pin.sh -u   # update the vendored copy, then check
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION_FILE="$ROOT/ThirdParty/libretro/CORE_REVISION"
HEADER="$ROOT/ThirdParty/libretro/include/libretro.h"
REPOSITORY="${SNES9X_RAW:-https://raw.githubusercontent.com/libretro/snes9x}"

REVISION="$(tr -d '[:space:]' < "$REVISION_FILE")"
if [ -z "$REVISION" ]; then
  echo "error: $REVISION_FILE is empty" >&2
  exit 1
fi

TEMP="$(mktemp)"
trap 'rm -f "$TEMP"' EXIT

URL="$REPOSITORY/$REVISION/libretro/libretro.h"
if ! curl -fsSL --max-time 30 "$URL" -o "$TEMP"; then
  echo "error: could not download $URL" >&2
  echo "       (offline? pass SNES9X_RAW to point at a reachable mirror)" >&2
  exit 1
fi

if [ "${1:-}" = "-u" ] || [ "${1:-}" = "--update" ]; then
  mkdir -p "$(dirname "$HEADER")"
  cp "$TEMP" "$HEADER"
  echo "updated $(realpath --relative-to="$ROOT" "$HEADER" 2>/dev/null || echo "$HEADER")"
fi

if cmp -s "$TEMP" "$HEADER"; then
  echo "libretro.h matches ${REVISION:0:12}"
  exit 0
fi

echo "error: the vendored libretro.h is not the one at ${REVISION:0:12}" >&2
echo >&2
diff -u "$HEADER" "$TEMP" | head -60 >&2 || true
echo >&2
echo "run 'scripts/verify-core-pin.sh --update' and re-check the constants in" >&2
echo "Sources/Core/LibretroConstants.swift against the diff above." >&2
exit 1
