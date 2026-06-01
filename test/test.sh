#!/usr/bin/env bash
# Launch an isolated Neovim that mirrors Robert's core ~/.config/nvim setup
# PLUS the local nvim-jupyter checkout, so the plugin can be validated in
# context WITHOUT integrating into the real config.
#
# Isolation: runs under NVIM_APPNAME=nvim-jupyter-test, so config/state/cache
# live in ~/.config/nvim-jupyter-test and ~/.local/{share,state}/nvim-jupyter-test.
# Installed plugins and mason servers are reused read-only (lazy `root` points
# at the real ~/.local/share/nvim/lazy). The real ~/.config/nvim is never touched.
#
# Usage:
#   ./test/test.sh                      # fresh throwaway copy of the fixture
#   ./test/test.sh path/to/other.ipynb  # opens a specific notebook as-is
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NVIM_APPNAME="nvim-jupyter-test"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$NVIM_APPNAME"

# Regenerate the isolated init each run so the repo path (and any config edits)
# stay current.
mkdir -p "$CONF_DIR"
sed "s|@@REPO@@|$REPO|g" "$REPO/test/repro-init.lua" > "$CONF_DIR/init.lua"

# Build the Rust daemon binary (lazy's build step would also run on first
# install; doing it here guarantees bin/nvim-jupyter exists before launch).
echo "Building nvim-jupyter daemon..."
bash "$REPO/build.sh"

# No argument: copy the pristine fixture to a gitignored scratch file (fresh each
# run) and open that, so editing/saving never dirties test/fixtures/simple.ipynb.
# An explicit path argument is opened directly, untouched.
if [ "$#" -ge 1 ]; then
  NB="$1"
else
  NB="$REPO/test/scratch.ipynb"
  cp -f "$REPO/test/fixtures/simple.ipynb" "$NB"
  echo "Fresh scratch copy: $NB (reset from fixture each run)"
fi

echo ""
echo "=== isolated test editor (NVIM_APPNAME=$NVIM_APPNAME) ==="
echo "Opening: $NB"
echo "Try: :JupyterKernelStatus  |  <S-CR> on a code cell  |  ]c / [c  |  :w"
echo ""
exec nvim "$NB"
