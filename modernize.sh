#!/bin/zsh
# Developer build (needs Xcode). Compiles YNABModern.dylib from the sources in src/, then runs
# patch.py, the same patcher users run, on the decrypted YNAB .ipa placed in this folder.
#
# Usage:
#   ./modernize.sh          -> YNABModern.dylib (the prebuilt copy patch.py ships with)
#                              and build/YNAB-modern.ipa (unsigned, for device sideloading)
#   ./modernize.sh --sim    -> also build/sim/YNAB.app (retargeted + ad-hoc signed for the iOS Simulator)
set -euo pipefail

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
HERE=${0:A:h}
OUT="$HERE/build"
DYLIB=YNABModern.dylib

build_dylib() { # <sdk> <target> <output> [extra sources...]
  local sdk=$1 target=$2 output=$3; shift 3
  xcrun --sdk $sdk clang -fobjc-arc -O2 -dynamiclib -target $target \
    -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
    -install_name @executable_path/$DYLIB -o "$output" "$HERE/src/YNABModern.m" "$HERE/src/YNABDefaultCleared.m" "$@"
}

rm -rf "$OUT/YNAB-modern.ipa" "$OUT/sim"   # only this script's own outputs
mkdir -p "$OUT"

# 1. The patch library, for devices. This copy is committed, so users don't need Xcode.
build_dylib iphoneos arm64-apple-ios14.0 "$HERE/$DYLIB"

# 2. Patch the IPA in this folder like a user would.
python3 "$HERE/patch.py" -o "$OUT/YNAB-modern.ipa" \
  ${BUNDLE_ID:+--bundle-id "$BUNDLE_ID"} ${VERSION:+--version "$VERSION"} ${DISPLAY_NAME:+--name "$DISPLAY_NAME"}
echo "Built $OUT/YNAB-modern.ipa"

if [[ ${1:-} == --sim ]]; then
  # The patched app, retargeted to the iOS Simulator (Apple Silicon only), with a simulator build of
  # the library that also includes a local-folder stand-in for Dropbox (see src/YNABFakeDropbox.m).
  (cd "$OUT" && rm -rf sim && mkdir sim && cd sim && unzip -q ../YNAB-modern.ipa && mv Payload/*.app . && rmdir Payload)
  SIM=$(echo "$OUT"/sim/*.app)
  BIN="$SIM/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SIM/Info.plist")"
  xcrun vtool -set-build-version iossim 14.0 12.4 -replace -output "$BIN.tmp" "$BIN" 2>/dev/null
  mv "$BIN.tmp" "$BIN"
  build_dylib iphonesimulator arm64-apple-ios14.0-simulator "$SIM/$DYLIB" "$HERE/src/YNABFakeDropbox.m"
  /usr/libexec/PlistBuddy -c "Set :CFBundleSupportedPlatforms:0 iPhoneSimulator" "$SIM/Info.plist"
  codesign -f -s - "$SIM" 2>/dev/null
  echo "Built $SIM"
fi
