#!/usr/bin/env bash
# Build Ionian Flow.app into build/ and sign it.
# Signs with the "Ionian Flow Dev" identity if present (run scripts/make-cert.sh once) so macOS keeps
# Microphone/Accessibility/Input Monitoring grants across rebuilds; otherwise falls back to ad-hoc.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Ionian Flow.app"

swift build -c release --package-path "$ROOT/app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/app/.build/release/IonianFlow" "$APP/Contents/MacOS/IonianFlow"
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/app/Resources/Fonts" "$APP/Contents/Resources/Fonts"
cp -R "$ROOT/app/Resources/Chrome" "$APP/Contents/Resources/Chrome"
sed "s|__ASR_DIR__|$ROOT/asr|" "$ROOT/app/Resources/Info.plist" > "$APP/Contents/Info.plist"

KC="$HOME/Library/Keychains/ionian-flow-signing.keychain-db"
if [[ -f "$KC" ]] && security find-certificate -c "Ionian Flow Dev" "$KC" >/dev/null 2>&1; then
  security unlock-keychain -p ionian-flow "$KC"
  codesign --force --keychain "$KC" --sign "Ionian Flow Dev" "$APP"
  echo "Signed with Ionian Flow Dev"
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed (permissions reset on every rebuild; run scripts/make-cert.sh to fix)"
fi
echo "Built $APP"
