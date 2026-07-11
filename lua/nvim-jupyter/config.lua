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
  },
  max_output_lines = 50,
  runtime_dir = nil,
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  if not M.options.runtime_dir then
    M.options.runtime_dir = vim.fn.stdpath("data") .. "/nvim-jupyter"
  end
  local hls = {
    NvimJupyterCellSep     = { link = "Comment" },
    NvimJupyterOutputText  = { link = "String" },
    NvimJupyterOutputError = { link = "ErrorMsg" },
    NvimJupyterOutputCount = { link = "Number" },
    NvimJupyterRunning     = { link = "WarningMsg" },
  }
  for name, def in pairs(hls) do
    vim.api.nvim_set_hl(0, name, def)
  end
end

return M
