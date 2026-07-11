local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {"c1_line1", "c1_line2", "c2_line1", "c2_line2"})
local ns = vim.api.nvim_create_namespace("test")
-- cell 1 mark at row 0
local m1 = vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {})
-- cell 2 mark at row 2
local m2 = vim.api.nvim_buf_set_extmark(bufnr, ns, 2, 0, {})

-- delete cell 1's last line (row 1)
vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {})
local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
for _, m in ipairs(marks) do
  print("Mark", m[1], "row", m[2])
end
