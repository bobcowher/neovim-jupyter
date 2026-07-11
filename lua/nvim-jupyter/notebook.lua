local M = {}

local function join_source(source_array)
  if type(source_array) == "string" then return source_array end
  return table.concat(source_array, "")
end

local function split_source(source_str)
  local lines = {}
  local remaining = source_str
  while true do
    local nl = remaining:find("\n")
    if not nl then
      table.insert(lines, remaining)
      break
    end
    table.insert(lines, remaining:sub(1, nl))
    remaining = remaining:sub(nl + 1)
  end
  return lines
end

function M.load(path)
  local lines = vim.fn.readfile(path)
  local raw = table.concat(lines, "\n")
  local decoded = vim.json.decode(raw)

  local cells = {}
  for _, raw_cell in ipairs(decoded.cells or {}) do
    table.insert(cells, {
      cell_type       = raw_cell.cell_type,
      id              = raw_cell.id,
      source          = join_source(raw_cell.source or {}),
      outputs         = raw_cell.outputs or {},
      execution_count = raw_cell.execution_count,
      metadata        = raw_cell.metadata or {},
    })
  end

  return {
    nbformat       = decoded.nbformat or 4,
    nbformat_minor = decoded.nbformat_minor or 5,
    metadata       = decoded.metadata or {},
    cells          = cells,
  }
end

function M.save(nb, path)
  local raw_cells = {}
  for _, cell in ipairs(nb.cells) do
    table.insert(raw_cells, {
      cell_type       = cell.cell_type,
      id              = cell.id or "",
      metadata        = cell.metadata or {},
      source          = split_source(cell.source),
      outputs         = cell.outputs or {},
      execution_count = cell.execution_count,
    })
  end

  local encoded = {
    nbformat       = nb.nbformat or 4,
    nbformat_minor = nb.nbformat_minor or 5,
    metadata       = nb.metadata or {},
    cells          = raw_cells,
  }

  local json_str = vim.json.encode(encoded)
  vim.fn.writefile({ json_str }, path)
end

function M.to_buffer_lines(nb)
  local lines = {}
  local cell_starts = {}
  for i, cell in ipairs(nb.cells) do
    cell_starts[i] = #lines + 1
    local source = cell.source
    local cell_lines = {}
    for line in (source .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(cell_lines, line)
    end
    if #cell_lines > 0 and cell_lines[#cell_lines] == "" then
      table.remove(cell_lines)
    end
    if #cell_lines == 0 then
      table.insert(cell_lines, "")
    end
    for _, l in ipairs(cell_lines) do
      table.insert(lines, l)
    end
  end
  return lines, cell_starts
end

return M
