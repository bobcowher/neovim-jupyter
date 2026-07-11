local nb = require("nvim-jupyter.notebook")
local init = require("nvim-jupyter.init")
local cells = require("nvim-jupyter.cells")
vim.cmd("edit test/fixtures/simple.ipynb")

local bufnr = vim.api.nvim_get_current_buf()
local marks = cells.get_marks(bufnr)
local mark_count = #marks
local index = mark_count

if index >= mark_count then
  cells.add_cell_below(bufnr, index)
end
local next_marks = cells.get_marks(bufnr)
if next_marks[index + 1] then
  local row = next_marks[index + 1].row
  local ok, err = pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, 0 })
  if not ok then
    print("ERROR: " .. err .. " | row=" .. row .. " | line_count=" .. vim.api.nvim_buf_line_count(bufnr))
  else
    print("SUCCESS: row=" .. row .. " | line_count=" .. vim.api.nvim_buf_line_count(bufnr))
  end
end
