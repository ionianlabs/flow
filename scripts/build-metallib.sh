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
# are left out. Output is cached, keyed on the resolved mlx-swift revision, the target and the Metal compiler.
#
# Env: MLX_SWIFT_DIR = an mlx-swift checkout (default: SwiftPM's app/.build/checkouts/mlx-swift, resolved on demand).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPPKG="$ROOT/app"
OUT="$APPPKG/.build/mlx.metallib"
MAJOR="$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1/p' "$APPPKG/Package.swift" | head -1)"
TARGET="${MLX_DEPLOYMENT_TARGET:-${MAJOR:-15}.0}"

if ! xcrun -sdk macosx -f metal >/dev/null 2>&1; then
  cat >&2 <<'MSG'
error: the Metal compiler is not available (`xcrun -f metal` fails).
       Building Ionian Flow needs the full Xcode, not only the command line tools:
         1. Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app
         2. xcodebuild -downloadComponent MetalToolchain
       Users of the built app need nothing.
MSG
  exit 1
fi

REV="$(sed -n '/"identity" : "mlx-swift"/,/}/p' "$APPPKG/Package.resolved" | sed -n 's/.*"revision" : "\([0-9a-f]*\)".*/\1/p' | head -1)"
[ -n "$REV" ] || { echo "error: mlx-swift revision not found in app/Package.resolved" >&2; exit 1; }

MLXSWIFT="${MLX_SWIFT_DIR:-$APPPKG/.build/checkouts/mlx-swift}"
if [ ! -d "$MLXSWIFT/Source/Cmlx/mlx" ]; then
  [ -z "${MLX_SWIFT_DIR:-}" ] || { echo "error: $MLX_SWIFT_DIR has no Source/Cmlx/mlx" >&2; exit 1; }
  swift package resolve --package-path "$APPPKG"
fi
MLXROOT="$MLXSWIFT/Source/Cmlx/mlx"
KDIR="$MLXROOT/mlx/backend/metal/kernels"
[ -d "$KDIR" ] || { echo "error: $KDIR missing" >&2; exit 1; }

VERSION_FLAG="-mmacosx-version-min=$TARGET"
# Same probe as MLX's CMake: the Metal language version the toolchain defaults to for this target.
METAL_VERSION="$(echo __METAL_VERSION__ | xcrun -sdk macosx metal "$VERSION_FLAG" -E -x metal -P - | tail -1)"
STAMP="$REV target=$TARGET metal=$METAL_VERSION $(xcrun -sdk macosx metal --version 2>&1 | head -1)"
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
