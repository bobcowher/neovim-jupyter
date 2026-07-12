local M = {}

M.defaults = {
  keymaps = true,
  keymap = {
    execute          = "<C-CR>",
    execute_advance  = "<S-CR>",
    execute_insert   = "<M-CR>",
    next_cell        = "]c",
    prev_cell        = "[c",
    delete_cell      = "<space>d",
    toggle_cell_type = "<space>m",
    add_cell_below   = "<space>b",
    add_cell_above   = "<space>a",
  },
  max_output_lines = 50,
  auto_save = true,
  runtime_dir = nil,
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  if not M.options.runtime_dir then
    M.options.runtime_dir = vim.fn.stdpath("data") .. "/nvim-jupyter"
  end
  local hls = {
    NvimJupyterCellSep        = { link = "Comment" },
    NvimJupyterMarkdown       = { link = "Normal" },
    NvimJupyterMarkdownH1     = { link = "@markup.heading.1" },
    NvimJupyterMarkdownH2     = { link = "@markup.heading.2" },
    NvimJupyterMarkdownH3     = { link = "@markup.heading.3" },
    NvimJupyterMarkdownH4     = { link = "@markup.heading.4" },
    NvimJupyterMarkdownH5     = { link = "@markup.heading.5" },
    NvimJupyterMarkdownH6     = { link = "@markup.heading.6" },
    NvimJupyterMarkdownBold   = { link = "@markup.strong" },
    NvimJupyterMarkdownItalic = { link = "@markup.italic" },
    NvimJupyterMarkdownCode   = { link = "@markup.raw" },
    NvimJupyterOutputText     = { link = "String" },
    NvimJupyterOutputError = { link = "ErrorMsg" },
    NvimJupyterOutputCount = { link = "Number" },
    NvimJupyterRunning     = { link = "WarningMsg" },
  }
  for name, def in pairs(hls) do
    vim.api.nvim_set_hl(0, name, def)
  end
end

return M
