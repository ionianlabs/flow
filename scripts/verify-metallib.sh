#!/usr/bin/env bash
# One-command check that the signed app ships and uses its own compiled mlx.metallib (unit K).
# Run after the Xcode license is accepted (`sudo xcodebuild -license accept`), from anywhere:
#     scripts/verify-metallib.sh
# Steps: (a) license + Metal Toolchain (downloads the toolchain if missing), (b) build the metallib, (c) build the app and
# compare the bundled metallib's sha256, (d) codesign --verify, (e) load Gemma and generate with the app's own binary and
# its bundled metallib (under the shared model lock), (f) sizes. Stops at the first FAIL.
# Env: LOCK_PY = the shared model lock wrapper (default: ~/_projects/ionian/native-bench/withlock.py; "none" to skip).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Ionian Flow.app"
LIB="$ROOT/app/.build/mlx.metallib"
LOCK_PY="${LOCK_PY:-$HOME/_projects/ionian/native-bench/withlock.py}"

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
mb() { awk -v b="$1" 'BEGIN{printf "%.1f MB", b/1048576}'; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

step "a) license and Metal Toolchain"
"$ROOT/scripts/build-metallib.sh" --check; rc=$?
if [ $rc -eq 11 ]; then
  echo "Metal Toolchain missing, downloading (no sudo needed)"
  DD="${DEVELOPER_DIR:-}"
  [ -n "$DD" ] || { [ -d /Applications/Xcode.app/Contents/Developer ] && DD=/Applications/Xcode.app/Contents/Developer; }
  DEVELOPER_DIR="$DD" xcodebuild -downloadComponent MetalToolchain || fail "xcodebuild -downloadComponent MetalToolchain"
  "$ROOT/scripts/build-metallib.sh" --check; rc=$?
fi
[ $rc -eq 10 ] && fail "Xcode license not accepted: run  sudo xcodebuild -license accept"
[ $rc -eq 0 ] || fail "Metal toolchain check (rc $rc)"
pass "license accepted, Metal compiler works"

step "b) build mlx.metallib"
"$ROOT/scripts/build-metallib.sh" || fail "scripts/build-metallib.sh"
[ -s "$LIB" ] || fail "$LIB missing or empty"
pass "mlx.metallib built: $(mb "$(stat -f %z "$LIB")")  sha256 $(sha "$LIB" | cut -c1-16)"

step "c) build the app and compare the bundled metallib"
"$ROOT/scripts/build-app.sh" || fail "scripts/build-app.sh"
BUNDLED="$APP/Contents/Resources/mlx.metallib"
[ -f "$BUNDLED" ] || fail "$BUNDLED does not exist"
[ "$(sha "$BUNDLED")" = "$(sha "$LIB")" ] || fail "bundled metallib differs from the built one"
pass "Contents/Resources/mlx.metallib present, sha256 equals the built metallib"

step "d) codesign"
codesign --verify --deep --strict --verbose=2 "$APP" || fail "codesign --verify --deep --strict"
pass "codesign verify (deep, strict)"

step "e) Gemma load and short generation with the app's own binary and bundled metallib"
BIN="$APP/Contents/MacOS/IonianFlow"
[ -x "$BIN" ] || fail "$BIN not executable"
lock() { if [ "$LOCK_PY" = none ]; then "$@"; else python3 "$LOCK_PY" "$@"; fi; }
unset IONIAN_FLOW_METALLIB   # the override would hide which copy is used
# Models: our own root if installed, else the developer HF cache (set IONIAN_FLOW_DEV_HF_CACHE=0 to forbid).
export IONIAN_FLOW_DEV_HF_CACHE="${IONIAN_FLOW_DEV_HF_CACHE:-1}"

# e1) load, and the metallib MLX is pointed at must be the bundle's.
OUT1="$(lock "$BIN" --enginetest-store gemma 2>&1)"; rc=$?
echo "$OUT1" | sed 's/^/    /'
[ $rc -eq 0 ] || fail "--enginetest-store gemma (rc $rc)"
echo "$OUT1" | grep -q "^ok   gemma loaded" || fail "Gemma did not load"
echo "$OUT1" | grep -qF "metallib: $APP/Contents/Resources/mlx.metallib" || fail "metallib in use is not the one inside the .app"
pass "Gemma loaded; MLX.GPU.metallib = the .app's Contents/Resources/mlx.metallib"

# e2) generation through the polish path (the model rewrites the sentence).
REQ='{"text":"so the the new build is like uh twenty percent faster i think"}'
OUT2="$( (echo "$REQ"; echo '{"cmd":"stats"}') | lock "$BIN" --enginetest-polish 2>&1)"; rc=$?
echo "$OUT2" | sed 's/^/    /'
[ $rc -eq 0 ] || fail "--enginetest-polish (rc $rc)"
echo "$OUT2" | grep -q '"text"' || fail "no generated text in the polish output"
pass "short generation succeeded with the bundled metallib"

# e3) negative control, informational: pointing MLX at a missing file shows whether the metallib matters at all.
if echo "$REQ" | IONIAN_FLOW_METALLIB=/nonexistent/mlx.metallib lock "$BIN" --enginetest-polish >/dev/null 2>&1; then
  echo "info  control run without any metallib also worked (MLX falls back to JIT for this path); e1 still proves which file is used"
else
  echo "info  control run without a metallib fails, so the generation above really used the bundled one"
fi

step "f) sizes"
APP_BYTES=$(du -sk "$APP" | cut -f1); APP_BYTES=$((APP_BYTES * 1024))
ZIP="$(mktemp -d)/IonianFlow.zip"
ditto -c -k --keepParent "$APP" "$ZIP" || fail "ditto"
pass ".app $(mb "$APP_BYTES"), compressed zip $(mb "$(stat -f %z "$ZIP")")"
rm -rf "$(dirname "$ZIP")"
echo; echo "ALL PASS"
