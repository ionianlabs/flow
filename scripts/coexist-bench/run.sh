#!/bin/sh
# Builds coexist-bench and runs it. Without Xcode SwiftPM cannot compile MLX's Metal kernels, so
# mlx.metallib is taken from the app build (run scripts/build-app.sh first) and put next to the binary.
#   run.sh [--minutes N] [--vocab FILE] [--log FILE] [--data DIR] [--llm DIR]
# --vocab (the bench term list) is required. Extra arguments go to coexist-bench.
# TODO(unit G): the metallib is copied from the app build for now; ModelStore/build-app.sh will own it.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/../../build/Ionian Flow.app/Contents/MacOS/mlx.metallib"
[ -f "$LIB" ] || { echo "error: $LIB missing; run scripts/build-app.sh first" >&2; exit 1; }
cd "$HERE" && swift build -c release
cp "$LIB" .build/release/mlx.metallib
exec .build/release/coexist-bench "$@"
