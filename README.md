# nvim-jupyter

A Neovim plugin that provides asynchronous Jupyter kernel integration. It uses a Rust backend to handle the ZeroMQ Jupyter protocol and a Lua frontend to manage cells, outputs, and kernels within Neovim.

## Features

- **Virtual Cell Buffer**: Open `.ipynb` notebooks directly. They are loaded as a virtual cell buffer.
- **Save/Load**: Saving the buffer (`:w`) automatically serializes your changes back into the `.ipynb` format.
- **Asynchronous Execution**: Communicates with kernels seamlessly without blocking the editor.
- **Inline Output**: Code cell outputs and errors are rendered directly below the cell using Neovim extmarks.

## Requirements

**Important:** This plugin renders inline output using modern terminal features and currently only works on **Kitty protocol compatible terminals** (such as [Kitty](https://sw.kovidgoyal.net/kitty/) or [Ghostty](https://ghostty.org/)).

## Installation & Setup

1. Install the plugin using your preferred package manager (e.g., `lazy.nvim`, `packer.nvim`).
2. The Rust backend needs to be compiled. You can do this by running the `:JupyterBuild` command in Neovim, or by manually running `bash build.sh` in the plugin directory.

## Usage

When you open an `.ipynb` file, the plugin automatically activates.

### Commands

**Execution:**
- `:JupyterExecute` — Execute the current cell in place.
- `:JupyterExecuteAndAdvance` — Execute the cell and move the cursor to the next one.
- `:JupyterExecuteAndInsert` — Execute the cell and insert a new one below.
- `:JupyterExecuteAll` — Execute all cells from top to bottom.

**Navigation & Editing:**
- `:JupyterNextCell` / `:JupyterPrevCell` — Move up or down between cells.
- `:JupyterAddCellBelow` / `:JupyterAddCellAbove` — Add new code cells.
- `:JupyterDeleteCell` — Delete the current cell.
- `:JupyterChangeCellType` — Toggle the cell between code and markdown.

**Kernel Management:**
- `:JupyterKernel` — Opens a picker to choose a Jupyter kernel.
- `:JupyterRestartKernel` — Restart the current kernel.
- `:JupyterInterrupt` — Interrupt the kernel (SIGINT).
- `:JupyterKernelStatus` — Check the current status of the kernel.

**Other:**
- `:JupyterShowOutput` — Show the full cell output in a scratch split window.
- `:JupyterBuild` — Compiles the Rust backend.

### Default Keybindings

If you rely on the default configuration, the following keybindings are set for you:

- `<C-CR>` (Control + Enter): Execute cell in place *(Note: Ghostty captures `ctrl+enter` by default to toggle the header. Use `shift+enter` or unbind `ctrl+enter` in Ghostty).*
- `<S-CR>` (Shift + Enter): Execute cell and advance
- `<M-CR>` (Alt/Option + Enter): Execute cell and insert below
- `]c`: Next cell
- `[c`: Previous cell

## Configuration

You can override default settings (such as keymaps) by calling `setup()` in your `init.lua`:

```lua
require('nvim-jupyter').setup({
  keymaps = true, -- set to false to disable default keymaps
  keymap = {
    execute          = "<C-CR>",
    execute_advance  = "<S-CR>",
    execute_insert   = "<M-CR>",
    next_cell        = "]c",
    prev_cell        = "[c",
  },
  max_output_lines = 50,
})
```
