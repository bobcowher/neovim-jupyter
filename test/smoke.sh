#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== nvim-jupyter smoke test ==="
echo ""

# 1. Build
echo "Step 1: Building binary..."
bash "$SCRIPT_DIR/build.sh"
echo "  ✓ binary built"

# 2. Test daemon responds to list_kernels
echo "Step 2: Testing daemon list_kernels..."
RESULT=$(printf '{"cmd":"list_kernels"}\n{"cmd":"quit"}\n' | "$SCRIPT_DIR/bin/nvim-jupyter" 2>/dev/null | head -1)
if echo "$RESULT" | grep -q '"event":"kernels_list"'; then
  echo "  ✓ kernels_list event received"
else
  echo "  ✗ unexpected output: $RESULT"
  exit 1
fi

# 3. Test daemon handles unknown command gracefully
echo "Step 3: Testing unknown command handling..."
RESULT=$(printf '{"cmd":"unknown_cmd"}\n{"cmd":"quit"}\n' | "$SCRIPT_DIR/bin/nvim-jupyter" 2>&1 | head -1)
echo "  ✓ handled without crash: $RESULT"

echo ""
echo "=== Automated checks passed ==="
echo ""
echo "Manual Neovim checks (run these yourself):"
echo "  1. nvim test/fixtures/simple.ipynb"
echo "     → Should see 3 cells with separator lines"
echo "     → :JupyterKernelStatus should print 'idle'"
echo "  2. Press <S-CR> on a cell"
echo "     → Output should appear as virtual text below"
echo "  3. Press ]c / [c to navigate between cells"
echo "  4. :w — should save without corrupting the .ipynb"
echo "  5. :JupyterRestartKernel — status should return to idle"
