#!/usr/bin/env bash
# Compiles MLX's Metal kernels into app/.build/mlx.metallib, the way MLX's own CMake build does
# (mlx/backend/metal/kernels/CMakeLists.txt in the mlx-swift checkout). The file ships inside the signed app
# (Contents/Resources/mlx.metallib, see build-app.sh). Nothing is downloaded at runtime.
#
# Needs Xcode (not only the command line tools) and its Metal Toolchain:
#     xcodebuild -downloadComponent MetalToolchain
#
# mlx-swift bundles MLX in JIT mode: most kernels are compiled on the device at run time from embedded sources, and
# only the kernels the CMake build lists outside `if(NOT MLX_METAL_JIT)` go into the metallib: arg_reduce, conv, dot,
# layer_norm, random, rms_norm, rope, scaled_dot_product_attention, plus fence when the Metal version is >= 3.2.
# Flags are CMake's METAL_FLAGS; the include root is the mlx source root (PROJECT_SOURCE_DIR); the deployment
# target is the package's (app/Package.swift, macOS 15). Debug-only flags (-gline-tables-only, -fmetal-enable-logging)
# are left out.
#
# Version pin: the MLX sources are the ones vendored in mlx-swift (Source/Cmlx/mlx), and mlx-swift is pinned by
# app/Package.resolved (exact revision). `swift package resolve --force-resolved-versions` checks out precisely that
# revision, and this script refuses a checkout whose HEAD differs, so the metallib always matches the MLX the Swift
# binary was built from.
# Incremental: the output is skipped when it exists and its stamp (mlx-swift revision, target, Metal compiler, hash of
# this script) is unchanged.
#
# Usage: build-metallib.sh [--check]   (--check only verifies license and toolchain; exit 10 = license not accepted,
#        11 = Metal Toolchain missing, 1 = other)
# Env: MLX_SWIFT_DIR = an mlx-swift checkout (default: SwiftPM's app/.build/checkouts/mlx-swift, resolved on demand).
set -euo pipefail
if [ "${1:-}" = "--check" ]; then CHECK_RC_LICENSE=10; CHECK_RC_TOOLCHAIN=11; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPPKG="$ROOT/app"
OUT="$APPPKG/.build/mlx.metallib"
MAJOR="$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1/p' "$APPPKG/Package.swift" | head -1)"
TARGET="${MLX_DEPLOYMENT_TARGET:-${MAJOR:-15}.0}"

# --- Xcode / Metal toolchain preflight -------------------------------------------------------------------------------
# xcode-select does not have to point at Xcode: when `xcrun -f metal` fails we try DEVELOPER_DIR=<newest Xcode*.app>.
# There is deliberately no fallback to a downloaded or borrowed metallib: either we compile it, or we stop here.
if ! xcrun -sdk macosx -f metal >/dev/null 2>&1; then
  XCODE_APP=""
  if [ -d /Applications/Xcode.app ]; then XCODE_APP=/Applications/Xcode.app
  else XCODE_APP="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1 || true)"; fi
  if [ -n "$XCODE_APP" ] && [ -d "$XCODE_APP/Contents/Developer" ]; then
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
    echo "note: xcode-select does not point at Xcode; using DEVELOPER_DIR=$DEVELOPER_DIR"
  fi
fi
classify() {  # $1 = tool output; exits with a precise fix when it recognises the problem
  case "$1" in
    *icense*)
      echo "error: the Xcode license is not accepted. Fix:" >&2
      echo "       sudo xcodebuild -license accept" >&2
      exit "${CHECK_RC_LICENSE:-1}" ;;
    *"issing Metal Toolchain"*|*MetalToolchain*|*"cannot execute"*|*"unable to find utility"*)
      echo "error: the Metal Toolchain is not installed. Fix:" >&2
      echo "       xcodebuild -downloadComponent MetalToolchain" >&2
      exit "${CHECK_RC_TOOLCHAIN:-1}" ;;
  esac
}
FOUND="$(xcrun -sdk macosx -f metal 2>&1)" || {
  classify "$FOUND"
  echo "error: the Metal compiler is not available (xcrun -f metal: $FOUND)." >&2
  echo "       Building Ionian Flow needs the full Xcode (App Store), not only the command line tools." >&2
  exit 1
}
PROBE="$(xcrun -sdk macosx metal --version 2>&1 || true)"
classify "$PROBE"
if ! echo "$PROBE" | head -1 | grep -qi "metal"; then
  echo "error: unexpected output from the Metal compiler: $PROBE" >&2
  echo "       If it mentions the toolchain: xcodebuild -downloadComponent MetalToolchain" >&2
  exit "${CHECK_RC_TOOLCHAIN:-1}"
fi
if [ "${1:-}" = "--check" ]; then echo "Metal toolchain ok: $(echo "$PROBE" | head -1)"; exit 0; fi

REV="$(sed -n '/"identity" : "mlx-swift"/,/}/p' "$APPPKG/Package.resolved" | sed -n 's/.*"revision" : "\([0-9a-f]*\)".*/\1/p' | head -1)"
[ -n "$REV" ] || { echo "error: mlx-swift revision not found in app/Package.resolved" >&2; exit 1; }

MLXSWIFT="${MLX_SWIFT_DIR:-$APPPKG/.build/checkouts/mlx-swift}"
if [ ! -d "$MLXSWIFT/Source/Cmlx/mlx" ]; then
  [ -z "${MLX_SWIFT_DIR:-}" ] || { echo "error: $MLX_SWIFT_DIR has no Source/Cmlx/mlx" >&2; exit 1; }
  swift package resolve --force-resolved-versions --package-path "$APPPKG"
fi
if [ -z "${MLX_SWIFT_DIR:-}" ] && [ -e "$MLXSWIFT/.git" ]; then
  HEAD_REV="$(git -C "$MLXSWIFT" rev-parse HEAD 2>/dev/null || true)"
  [ "$HEAD_REV" = "$REV" ] || { echo "error: $MLXSWIFT is at ${HEAD_REV:-unknown}, Package.resolved pins $REV (run: swift package resolve --force-resolved-versions --package-path app)" >&2; exit 1; }
fi
MLXROOT="$MLXSWIFT/Source/Cmlx/mlx"
KDIR="$MLXROOT/mlx/backend/metal/kernels"
[ -d "$KDIR" ] || { echo "error: $KDIR missing" >&2; exit 1; }

VERSION_FLAG="-mmacosx-version-min=$TARGET"
# Same probe as MLX's CMake: the Metal language version the toolchain defaults to for this target.
METAL_VERSION="$(echo __METAL_VERSION__ | xcrun -sdk macosx metal "$VERSION_FLAG" -E -x metal -P - | tail -1)"
STAMP="$REV target=$TARGET metal=$METAL_VERSION $(echo "$PROBE" | head -1) script=$(shasum -a 256 "$0" | cut -c1-16)"
if [ -f "$OUT" ] && [ -f "$OUT.stamp" ] && [ "$(cat "$OUT.stamp")" = "$STAMP" ]; then
  echo "mlx.metallib up to date ($OUT)"
  exit 0
fi

KERNELS=(arg_reduce conv dot layer_norm random rms_norm rope scaled_dot_product_attention)
if [ "$METAL_VERSION" -ge 320 ] 2>/dev/null; then KERNELS+=(fence); fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FLAGS=(-x metal -Wall -Wextra -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions -Wmetal-addr-spaces "$VERSION_FLAG")
AIRS=()
for k in "${KERNELS[@]}"; do
  echo "metal $k.metal"
  xcrun -sdk macosx metal "${FLAGS[@]}" -c "$KDIR/$k.metal" -I"$MLXROOT" -o "$WORK/$k.air"
  AIRS+=("$WORK/$k.air")
done
xcrun -sdk macosx metal "$VERSION_FLAG" "${AIRS[@]}" -o "$WORK/mlx.metallib"
mkdir -p "$(dirname "$OUT")"
cp "$WORK/mlx.metallib" "$OUT"
echo "$STAMP" > "$OUT.stamp"
echo "Built $OUT (Metal $METAL_VERSION, macOS $TARGET+, mlx-swift ${REV:0:7})"
