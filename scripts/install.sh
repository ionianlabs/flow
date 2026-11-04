#!/usr/bin/env bash
# From a fresh clone to a running Ionian Flow: signing identity, build, open. Safe to run again.
# The models are not part of this: the app downloads them on first launch. Usage: scripts/install.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

step() { printf '\n\033[1;1m▍ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$1"; exit 1; }

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail "Ionian Flow needs a Mac with Apple Silicon."
command -v swift >/dev/null || fail "Swift is missing. Install the Command Line Tools: xcode-select --install"

step "1/2  Code signature (keeps macOS permissions across updates)"
scripts/make-cert.sh

step "2/2  Building Ionian Flow.app"
scripts/build-app.sh

step "Done. Opening Ionian Flow; the setup guide downloads the models."
open "build/Ionian Flow.app"
