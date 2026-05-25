#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
cargo build --release
mkdir -p bin
cp target/release/nvim-jupyter bin/nvim-jupyter
echo "nvim-jupyter: build complete — bin/nvim-jupyter ready"
