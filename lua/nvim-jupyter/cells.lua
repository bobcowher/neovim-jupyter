local M = {}

M._state = {}

function M._split_source_to_lines(source)
  local lines = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
  if #lines == 0 then lines = { "" } end
  return lines
end

function M._join_lines_to_source(lines)
  return table.concat(lines, "\n")
end

local function sep_virt_line(cell_type, hl)
  local label = "─── " .. (cell_type or "code") .. " "
  local fill = string.rep("─", math.max(0, 60 - #label))
  return { { label .. fill, hl or "NvimJupyterCellSep" } }
end

function M.init(bufnr, nb, lines, cell_starts)
  local ns_cells  = vim.api.nvim_create_namespace("nvim_jupyter_cells_" .. bufnr)
  local ns_output = vim.api.nvim_create_namespace("nvim_jupyter_output_" .. bufnr)
  M._state[bufnr] = { ns_cells = ns_cells, ns_output = ns_output, cell_meta = {}, cell_output = {} }

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  for i, cell in ipairs(nb.cells) do
    local row = cell_starts[i] - 1
    local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns_cells, row, 0, {
      virt_lines = { sep_virt_line(cell.cell_type) },
      virt_lines_above = true,
      hl_mode = "combine",
    })
    M._state[bufnr].cell_meta[mark_id] = {
      cell_type       = cell.cell_type,
      id              = cell.id or "",
      outputs         = cell.outputs or {},
      execution_count = cell.execution_count,
      metadata        = cell.metadata or {},
    }
  end
end

function M.get_marks(bufnr)
  local s = M._state[bufnr]
  if not s then return {} end
  local raw = vim.api.nvim_buf_get_extmarks(bufnr, s.ns_cells, 0, -1, { details = false })
  local marks = {}
  for _, m in ipairs(raw) do
    table.insert(marks, { id = m[1], row = m[2], meta = s.cell_meta[m[1]] })
  end
  table.sort(marks, function(a, b) return a.row < b.row end)
  return marks
end

function M.cell_at_row(bufnr, row)
  local marks = M.get_marks(bufnr)
  local found = nil
  for i, mark in ipairs(marks) do
    if mark.row <= row then
      found = { index = i, mark = mark }
    else
      break
    end
  end
  return found
end

function M.cell_range(bufnr, index)
  local marks = M.get_marks(bufnr)
  if not marks[index] then return nil end
  local start_row = marks[index].row
  local end_row
  if marks[index + 1] then
    end_row = marks[index + 1].row
  else
    end_row = vim.api.nvim_buf_line_count(bufnr)
  end
  return start_row, end_row
end

function M.get_source(bufnr, index)
  local start_row, end_row = M.cell_range(bufnr, index)
  if not start_row then return "" end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
  return M._join_lines_to_source(lines)
end

function M.add_cell_below(bufnr, index)
  local s = M._state[bufnr]
  if not s then return end
  local _, end_row = M.cell_range(bufnr, index)
  vim.api.nvim_buf_set_lines(bufnr, end_row, end_row, false, { "" })
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, s.ns_cells, end_row, 0, {
    virt_lines = { sep_virt_line("code") },
    virt_lines_above = true,
    hl_mode = "combine",
  })
  s.cell_meta[mark_id] = { cell_type = "code", id = "", outputs = {}, execution_count = nil, metadata = {} }
  return index + 1
end

function M.add_cell_above(bufnr, index)
  local s = M._state[bufnr]
  if not s then return end
  local start_row = M.get_marks(bufnr)[index].row
  vim.api.nvim_buf_set_lines(bufnr, start_row, start_row, false, { "" })
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, s.ns_cells, start_row, 0, {
    virt_lines = { sep_virt_line("code") },
    virt_lines_above = true,
    hl_mode = "combine",
  })
  s.cell_meta[mark_id] = { cell_type = "code", id = "", outputs = {}, execution_count = nil, metadata = {} }
  return index
end

function M.delete_cell(bufnr, index)
  local s = M._state[bufnr]
  if not s then return end
  local marks = M.get_marks(bufnr)
  if not marks[index] then return end
  local start_row, end_row = M.cell_range(bufnr, index)
  -- Drop any output owned by this cell so its extmark doesn't outlive it.
  if s.cell_output and s.cell_output[marks[index].id] then
    local e = s.cell_output[marks[index].id]
    if e.ext then pcall(vim.api.nvim_buf_del_extmark, bufnr, s.ns_output, e.ext) end
    s.cell_output[marks[index].id] = nil
  end
  vim.api.nvim_buf_del_extmark(bufnr, s.ns_cells, marks[index].id)
  s.cell_meta[marks[index].id] = nil
  vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, {})
end

function M.toggle_cell_type(bufnr, index)
  local s = M._state[bufnr]
  if not s then return end
  local marks = M.get_marks(bufnr)
  if not marks[index] then return end
  local meta = s.cell_meta[marks[index].id]
  meta.cell_type = meta.cell_type == "code" and "markdown" or "code"
  vim.api.nvim_buf_set_extmark(bufnr, s.ns_cells, marks[index].row, 0, {
    id = marks[index].id,
    virt_lines = { sep_virt_line(meta.cell_type) },
    virt_lines_above = true,
    hl_mode = "combine",
  })
end

function M.to_notebook_cells(bufnr)
  local s = M._state[bufnr]
  if not s then return {} end
  local marks = M.get_marks(bufnr)
  local cells = {}
  for i, mark in ipairs(marks) do
    local start_row, end_row = M.cell_range(bufnr, i)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
    if i > 1 and mark.row == marks[i-1].row then
      vim.notify("nvim-jupyter: cell boundary merge detected — merging cells " .. (i-1) .. " and " .. i, vim.log.levels.WARN)
    end
    local meta = mark.meta or {}
    table.insert(cells, {
      cell_type       = meta.cell_type or "code",
      id              = meta.id or "",
      source          = M._join_lines_to_source(lines),
      outputs         = meta.outputs or {},
      execution_count = meta.execution_count,
      metadata        = meta.metadata or {},
    })
  end
  return cells
end

return M
