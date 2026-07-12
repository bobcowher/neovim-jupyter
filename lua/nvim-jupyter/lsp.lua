local kernels = require("nvim-jupyter.kernels")
local cells = require("nvim-jupyter.cells")

local M = {}

M._last_completion = nil

function M.omnifunc(findstart, base)
  local bufnr = vim.api.nvim_get_current_buf()
  if findstart == 1 then
    if not kernels.is_ready(bufnr) then
      return -3 -- Cancel completion
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1
    local col = cursor[2]
    
    -- Extract the code of the current cell up to the cursor
    local info = cells.cell_at_row(bufnr, row)
    if not info then return -3 end
    if info.meta and info.meta.cell_type ~= "code" then return -3 end

    local start_row, end_row = cells.cell_range(bufnr, info.index)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
    
    -- Calculate the exact character offset of the cursor within the cell
    local code = table.concat(lines, "\n")
    local cursor_pos = 0
    for i = 1, row - start_row do
      cursor_pos = cursor_pos + #lines[i] + 1
    end
    cursor_pos = cursor_pos + col
    
    -- Request completion
    local msg_id = kernels.new_msg_id()
    local result = nil
    kernels.register_callback(msg_id, function(ev)
      result = ev
    end)
    kernels.complete(bufnr, msg_id, code, cursor_pos)
    
    -- Wait up to 2 seconds for reply
    vim.wait(2000, function() return result ~= nil end, 10)
    
    if result and result.matches and #result.matches > 0 then
      M._last_completion = result.matches
      
      -- Convert 0-indexed absolute character position to byte column on current line
      -- Jupyter cursor_start is relative to the start of the cell code!
      local prefix_len = cursor_pos - result.cursor_start
      return col - prefix_len
    end
    
    M._last_completion = nil
    return -3
  else
    return M._last_completion or {}
  end
end

function M.hover()
  local bufnr = vim.api.nvim_get_current_buf()
  if not kernels.is_ready(bufnr) then return end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]
  
  local info = cells.cell_at_row(bufnr, row)
  if not info or (info.meta and info.meta.cell_type ~= "code") then return end

  local start_row, end_row = cells.cell_range(bufnr, info.index)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
  local code = table.concat(lines, "\n")
  local cursor_pos = 0
  for i = 1, row - start_row do
    cursor_pos = cursor_pos + #lines[i] + 1
  end
  cursor_pos = cursor_pos + col
  
  local msg_id = kernels.new_msg_id()
  local result = nil
  kernels.register_callback(msg_id, function(ev)
    result = ev
  end)
  kernels.inspect(bufnr, msg_id, code, cursor_pos, 0)
  
  vim.wait(2000, function() return result ~= nil end, 10)
  
  if result and result.found and result.text and #result.text > 0 then
    -- Show hover window
    local text = result.text:gsub("\r", "")
    
    -- Strip ANSI escape codes that Jupyter includes for terminal coloring
    text = text:gsub("\27%[[0-9;]*[a-zA-Z]", "")
    
    local split = vim.split(text, "\n")
    vim.lsp.util.open_floating_preview(split, "markdown", {
      border = "rounded",
    })
  else
    vim.notify("nvim-jupyter: No inspection data found", vim.log.levels.INFO)
  end
end

return M
