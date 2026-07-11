local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {"line1", "line2", "line3"})
local ns = vim.api.nvim_create_namespace("test")
-- set extmark at row 1 (line2)
local m1 = vim.api.nvim_buf_set_extmark(bufnr, ns, 1, 0, {})
-- delete line2
vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {})
local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
print("Mark after delete:", marks[1][2])
