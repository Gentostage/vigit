#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

lua tests/run.lua
nvim --headless --clean -u NONE -l tests/integration/run.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua
lua scripts/generate-keymaps.lua --check
