#!/bin/sh
# Builds coexist-bench and runs it. mlx.metallib comes from scripts/build-metallib.sh (needs Xcode + Metal Toolchain)
# and is put next to the binary, where MLX looks first.
#   run.sh [--minutes N] [--vocab FILE] [--log FILE] [--data DIR] [--llm DIR]
# --vocab (the bench term list) is required. Extra arguments go to coexist-bench.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/../build-metallib.sh"
cd "$HERE" && swift build -c release
cp "$HERE/../../app/.build/mlx.metallib" .build/release/mlx.metallib
exec .build/release/coexist-bench "$@"
