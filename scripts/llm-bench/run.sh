#!/bin/sh
# Builds llm-bench and runs asr/bench_llm.py against it, then against Python mlx-lm for comparison.
# Without Xcode SwiftPM cannot compile MLX's Metal kernels, so mlx.metallib is borrowed from the Python
# mlx wheel (MLX_PY = a python with `mlx` installed; the wheel should match mlx-swift's vendored core,
# 0.32.x) and put next to the binary, where MLX looks first.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PY=${MLX_PY:-$HERE/../../asr/.venv/bin/python}
cd "$HERE" && swift build -c release
LIB=$("$PY" -c 'import mlx, os; print(os.path.join(os.path.dirname(mlx.__file__), "lib", "mlx.metallib"))')
cp "$LIB" .build/release/mlx.metallib
cd "$HERE/../../asr"
export HF_HUB_OFFLINE=1
"$PY" bench_llm.py --task polish --show swift:"$HERE/.build/release/llm-bench"
"$PY" bench_llm.py --task polish --show mlx:mlx-community/gemma-4-e2b-it-4bit
