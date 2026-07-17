#!/usr/bin/env bash
#
# muninn end-to-end test runner.
#
# Runs the layered bats suite in e2e/tests/. It proves, per layer, that muninn
# delivers its convention and steers a real `claude` run — see e2e/README.md.
#
# `bats` and the bats-support/bats-assert libraries are provided by the
# devcontainer image (.devcontainer/Dockerfile); BATS_LIB_PATH points at them.
#
# Usage:
#   bash e2e/run.sh                        # run the whole suite
#   bash e2e/run.sh --filter 'Layer 2'     # extra flags pass through to bats
#
# Live checks skip cleanly when `claude` is unavailable, so this is safe to run
# anywhere the image provides bats.
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# bats resolves `bats_load_library` via BATS_LIB_PATH. The devcontainer image
# sets it (ENV), but default it to the image's install location too, so the suite
# runs even when that env var is not exported into the current shell.
export BATS_LIB_PATH="${BATS_LIB_PATH:-/usr/local/lib/bats}"

if ! command -v bats >/dev/null 2>&1; then
  echo "!! bats not found on PATH."
  echo "!! It ships in the devcontainer image (.devcontainer/Dockerfile) — rebuild it,"
  echo "!! or install bats-core + bats-support + bats-assert to run this suite."
  exit 127
fi

exec bats "$@" "$E2E_DIR/tests"
