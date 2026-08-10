#!/bin/bash
# Packages the core-only iOS builds (device + simulator) into a single
# OrcaCore.xcframework for the iPad app.
#
# Prerequisites (see the iPad-port build notes):
#   deps/build/ios      + build/ios      : device build   (cmake ... ios.toolchain.cmake)
#   deps/build/ios-sim  + build/ios-sim  : simulator build (+ -DCMAKE_OSX_SYSROOT=iphonesimulator)
#   Both configured with -DORCA_CORE_ONLY=1 and target libslic3r built.
#
# Usage: scripts/make_ios_xcframework.sh [output-dir]   (default: ios-app/Frameworks)

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$REPO/ios-app/Frameworks}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

merge_platform() {
    local flavor="$1"    # ios | ios-sim
    local out_a="$2"
    local app_build="$REPO/build/$flavor"
    local dep_lib="$REPO/deps/build/$flavor/OrcaSlicer_dep_ios/usr/local/lib"

    [ -f "$app_build/src/libslic3r/liblibslic3r.a" ] || {
        echo "error: $app_build has no liblibslic3r.a - build target libslic3r first" >&2; exit 1; }

    # Every static library from the core build tree (libslic3r, in-tree deps
    # like admesh/clipper/mcut) plus the cross-compiled dependency bundle.
    find "$app_build" -name '*.a' > "$WORK/$flavor.list"
    find "$dep_lib" -maxdepth 1 -name '*.a' >> "$WORK/$flavor.list"

    # libtool flattens them into one archive; duplicate member basenames are
    # fine (contents get merged), duplicate symbols are not - the core build
    # has none.
    libtool -static -no_warning_for_no_symbols -o "$out_a" $(cat "$WORK/$flavor.list")
    echo "merged $(wc -l < "$WORK/$flavor.list" | tr -d ' ') archives -> $out_a"
}

mkdir -p "$WORK/device" "$WORK/sim"
merge_platform ios     "$WORK/device/libOrcaCore.a"
merge_platform ios-sim "$WORK/sim/libOrcaCore.a"

rm -rf "$OUT/OrcaCore.xcframework"
mkdir -p "$OUT"
xcodebuild -create-xcframework \
    -library "$WORK/device/libOrcaCore.a" \
    -library "$WORK/sim/libOrcaCore.a" \
    -output "$OUT/OrcaCore.xcframework"

echo "OK: $OUT/OrcaCore.xcframework"
