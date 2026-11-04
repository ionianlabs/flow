#!/usr/bin/env bash
# Build Ionian Flow.app into build/ and sign it.
# Signs with the "Ionian Flow Dev" identity if present (run scripts/make-cert.sh once) so macOS keeps
# Microphone/Accessibility/Input Monitoring grants across rebuilds; otherwise falls back to ad-hoc.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Ionian Flow.app"

swift build -c release --package-path "$ROOT/app"
# MLX's Metal kernels, compiled from the mlx-swift sources (needs Xcode + Metal Toolchain, see build-metallib.sh).
# Runs before the bundle is assembled so a missing compiler fails early; the package is resolved by now.
"$ROOT/scripts/build-metallib.sh"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/app/.build/release/IonianFlow" "$APP/Contents/MacOS/IonianFlow"
# Swift 6.2 back-deployment library: macOS 26 has it in /usr/lib/swift, macOS 15 does not, and the binary would
# otherwise only find it in the Xcode toolchain rpath (absent on a user's Mac). Ship it next to the binary.
if otool -L "$APP/Contents/MacOS/IonianFlow" | grep -q "@rpath/libswiftCompatibilitySpan.dylib"; then
  SPAN="$(dirname "$(xcrun --find swift)")/../lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib"
  [ -f "$SPAN" ] || SPAN="$(dirname "$(xcrun --find swift)")/../lib/swift/macosx/libswiftCompatibilitySpan.dylib"
  mkdir -p "$APP/Contents/Frameworks"
  cp "$SPAN" "$APP/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/IonianFlow"
  codesign --force --sign - "$APP/Contents/Frameworks/libswiftCompatibilitySpan.dylib" >/dev/null 2>&1 || true
fi
# Drop rpaths into this Mac's toolchains (Xcode, Metal Toolchain cryptex): they do not exist on a user's Mac.
otool -l "$APP/Contents/MacOS/IonianFlow" | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | while read -r p; do
  case "$p" in /Applications/*|/Library/Developer/*|/var/run/*|/private/var/run/*) install_name_tool -delete_rpath "$p" "$APP/Contents/MacOS/IonianFlow" ;; esac
done
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/app/Resources/Fonts" "$APP/Contents/Resources/Fonts"
cp -R "$ROOT/app/Resources/Chrome" "$APP/Contents/Resources/Chrome"
cp "$ROOT/app/Resources/ThirdPartyNotices.md" "$APP/Contents/Resources/ThirdPartyNotices.md"
# Resources/, not MacOS/: codesign rejects loose data files next to the binary. ModelStore.activateMetallib points
# MLX.GPU.metallib there.
cp "$ROOT/app/.build/mlx.metallib" "$APP/Contents/Resources/mlx.metallib"
# Word-frequency table for VocabNormalizer (committed data, CC BY-SA 4.0; see ThirdPartyNotices.md).
if [ -f "$ROOT/app/Resources/wordfreq.tsv" ]; then cp "$ROOT/app/Resources/wordfreq.tsv" "$APP/Contents/Resources/wordfreq.tsv"; fi
cp "$ROOT/app/Resources/Info.plist" "$APP/Contents/Info.plist"

KC="$HOME/Library/Keychains/ionian-flow-signing.keychain-db"
if [[ -f "$KC" ]] && security find-certificate -c "Ionian Flow Dev" "$KC" >/dev/null 2>&1; then
  security unlock-keychain -p ionian-flow "$KC"
  codesign --force --keychain "$KC" --sign "Ionian Flow Dev" "$APP"
  echo "Signed with Ionian Flow Dev"
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed (permissions reset on every rebuild; run scripts/make-cert.sh to fix)"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP"
