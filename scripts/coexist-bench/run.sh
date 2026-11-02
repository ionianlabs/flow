#!/bin/sh
# Builds coexist-bench and runs it. Without Xcode SwiftPM cannot compile MLX's Metal kernels, so
# mlx.metallib is borrowed from the Python mlx wheel (as in ../llm-bench/run.sh) and put next to the binary.
#   run.sh [--minutes N] [--vocab FILE] [--log FILE] [--data DIR] [--llm DIR]
# --vocab (the bench term list) is required. Extra arguments go to coexist-bench.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PY=${MLX_PY:-$HERE/../../asr/.venv/bin/python}
cd "$HERE" && swift build -c release
LIB=$("$PY" -c 'import mlx, os; print(os.path.join(os.path.dirname(mlx.__file__), "lib", "mlx.metallib"))')
cp "$LIB" .build/release/mlx.metallib
export HF_HUB_OFFLINE=1
exec .build/release/coexist-bench "$@"
