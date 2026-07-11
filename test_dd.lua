local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {"print(x)", "print(y)"})
local ns = vim.api.nvim_create_namespace("test")
-- set extmark at row 1 (the second line)
local m1 = vim.api.nvim_buf_set_extmark(bufnr, ns, 1, 0, {})

-- delete first line
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})
-- check mark
local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
print("Mark after delete:", marks[1][2])

-- what if we use Lua to just replace the line?
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {""})
marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
print("Mark after replace:", marks[1][2])
