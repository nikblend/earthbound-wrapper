#!/usr/bin/env bash
#
# build-core.sh — build the pinned snes9x libretro core for iOS.
#
# Produces one static archive per SDK:
#
#     Core/lib/iphoneos/libsnes9x.a
#     Core/lib/iphonesimulator/libsnes9x.a
#
# Static, not a dylib. A dynamic core would mean a nested Mach-O to sign, a copy
# into the bundle, and a dlopen that can fail on the player's device for reasons
# that have nothing to do with emulation. A static archive turns every one of those
# into a link error on the build machine.
#
# Why the core's own Makefile rather than a hand-written build: snes9x's source
# list changes between revisions, and `Makefile.common` is the only thing that
# knows it. We only steer the parts that decide the target and the SDK.
#
# Usage:
#   scripts/build-core.sh                     # device only (what an IPA needs)
#   scripts/build-core.sh iphoneos iphonesimulator
#
set -euo pipefail

REPOSITORY="${SNES9X_REPOSITORY:-https://github.com/libretro/snes9x.git}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION_FILE="$ROOT/ThirdParty/libretro/CORE_REVISION"
WORK_ROOT="${BUILD_DIR:-$ROOT/.build}"
OUTPUT_ROOT="$ROOT/Core/lib"

SDKS=("$@")
if [ ${#SDKS[@]} -eq 0 ]; then
  SDKS=(iphoneos)
fi

if [ ! -f "$REVISION_FILE" ]; then
  echo "error: $REVISION_FILE is missing; it pins the core revision" >&2
  exit 1
fi
REVISION="$(tr -d '[:space:]' < "$REVISION_FILE")"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. This script needs macOS with Xcode." >&2
  exit 1
fi

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# Fetches the pinned revision into a per-SDK working tree.
#
# One tree per SDK rather than one tree and a `make clean` between builds: the
# core's Makefile writes its object files next to the sources, so sharing a tree
# means the second build silently reuses the first one's objects, compiled against
# the other SDK's headers. Two shallow fetches of a few megabytes is a cheap price
# for a build that cannot be wrong that way.
fetch_source() {
  local destination="$1"
  if [ -f "$destination/.eb-revision" ] && \
     [ "$(cat "$destination/.eb-revision")" = "$REVISION" ]; then
    echo "  source already at ${REVISION:0:12}"
    return
  fi

  echo "  fetching ${REVISION:0:12}"
  rm -rf "$destination"
  mkdir -p "$destination"
  git -C "$destination" init --quiet
  git -C "$destination" remote add origin "$REPOSITORY"
  git -C "$destination" fetch --quiet --depth 1 origin "$REVISION"
  git -C "$destination" checkout --quiet FETCH_HEAD
  echo "$REVISION" > "$destination/.eb-revision"
}

build_sdk() {
  local sdk="$1"
  local destination="$WORK_ROOT/$sdk"
  local output="$OUTPUT_ROOT/$sdk"

  echo "==> $sdk"

  local sdk_path
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

  # The iOS platform branch in the core's Makefile hard-codes
  # `-miphoneos-version-min=8.0` and picks the device SDK with `xcodebuild`. Both
  # are overridable from the command line, which is how this builds against the
  # simulator SDK while still using the platform branch that has the right
  # `-DIOS -DARM` defines. Getting the minimum version wrong here is not a warning:
  # a simulator build with a device deployment target links against the wrong stubs.
  local minimum_version
  if [ "$sdk" = "iphoneos" ]; then
    minimum_version="-miphoneos-version-min=17.0"
  else
    minimum_version="-mios-simulator-version-min=17.0"
  fi

  fetch_source "$destination"
  mkdir -p "$output"

  # - lsnes9x.a is built with STATIC_LINKING=0 (the default), so the core's
  #   vendored libretro-common is compiled in and the archive is self-contained.
  #   STATIC_LINKING=1 would omit it, on the assumption that the frontend provides
  #   those symbols — which RetroArch does and this app does not.
  # - STATIC_LINKING_LINK=1 switches the link step from `-dynamiclib` to `ar`.
  # - TARGET is overridden to the archive name; the platform branch would otherwise
  #   name it snes9x_libretro_ios.dylib.
  make -C "$destination/libretro" -f Makefile \
    platform=ios-arm64 \
    TARGET="$output/libsnes9x.a" \
    STATIC_LINKING_LINK=1 \
    AR="$(xcrun --find ar)" \
    IOSSDK="$sdk_path" \
    MINVERSION="$minimum_version" \
    -j"$JOBS"

  if [ ! -f "$output/libsnes9x.a" ]; then
    echo "error: expected $output/libsnes9x.a was not produced" >&2
    exit 1
  fi

  echo "  -> ${output#$ROOT/}/libsnes9x.a"
  lipo -info "$output/libsnes9x.a" | sed 's/^/     /'
}

echo "snes9x libretro core @ ${REVISION:0:12}"
for sdk in "${SDKS[@]}"; do
  build_sdk "$sdk"
done

echo "core built"
