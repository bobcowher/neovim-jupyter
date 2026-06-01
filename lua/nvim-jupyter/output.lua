local M = {}

function M._strip_ansi(s)
  return s:gsub("\27%[[%d;]*m", "")
end

function M._text_to_lines(text)
  local lines = {}
  for line in (text):gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

function M._truncate(lines, max_lines)
  if #lines <= max_lines then return lines end
  local result = {}
  for i = 1, max_lines do result[i] = lines[i] end
  table.insert(result, string.format("[... %d more lines]", #lines - max_lines))
  return result
end

local function build_virt_lines(lines, hl)
  local vl = {}
  for _, line in ipairs(lines) do
    table.insert(vl, { { "▷ " .. line, hl } })
  end
  return vl
end

function M.set(bufnr, ns_output, last_row, text_lines, hl, max_output_lines)
  M.clear(bufnr, ns_output, last_row)

  local truncated = M._truncate(text_lines, max_output_lines or 50)
  local vl = build_virt_lines(truncated, hl or "NvimJupyterOutputText")

  vim.api.nvim_buf_set_extmark(bufnr, ns_output, last_row, 0, {
    virt_lines = vl,
    virt_lines_above = false,
    hl_mode = "combine",
  })
end

function M.append(bufnr, ns_output, last_row, new_lines, hl, max_output_lines)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_output, { last_row, 0 }, { last_row, 0 }, { details = true })
  local existing = {}
  local existing_id = nil
  if #marks > 0 then
    existing_id = marks[1][1]
    local details = marks[1][4]
    if details and details.virt_lines then
      for _, vl in ipairs(details.virt_lines) do
        if vl[1] then
          table.insert(existing, vl[1][1]:sub(3))
        end
      end
    end
    if #existing > 0 and existing[#existing]:find("more lines") then
      table.remove(existing)
    end
  end

  for _, l in ipairs(new_lines) do
    table.insert(existing, l)
  end

  local truncated = M._truncate(existing, max_output_lines or 50)
  local vl = build_virt_lines(truncated, hl or "NvimJupyterOutputText")

  local opts = {
    virt_lines = vl,
    virt_lines_above = false,
    hl_mode = "combine",
  }
  if existing_id then opts.id = existing_id end
  vim.api.nvim_buf_set_extmark(bufnr, ns_output, last_row, 0, opts)
end

-- Set output virt_lines at `row`, returning the new extmark id. If `prev_id`
-- is given, that extmark is deleted first — so output can follow a cell whose
-- last line moved (buffer edits, inserted cells) without leaving a stale copy.
function M.set_at(bufnr, ns_output, row, text_lines, hl, max_output_lines, prev_id)
  if prev_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_output, prev_id)
  end
  local truncated = M._truncate(text_lines, max_output_lines or 50)
  local vl = build_virt_lines(truncated, hl or "NvimJupyterOutputText")
  return vim.api.nvim_buf_set_extmark(bufnr, ns_output, row, 0, {
    virt_lines = vl,
    virt_lines_above = false,
    hl_mode = "combine",
  })
end

-- Remove every output extmark anchored within the [start_row, end_row) range.
function M.clear_range(bufnr, ns_output, start_row, end_row)
  local last = math.max(start_row, end_row - 1)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_output, { start_row, 0 }, { last, -1 }, {})
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_del_extmark(bufnr, ns_output, m[1])
  end
end

function M.clear(bufnr, ns_output, last_row)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_output, { last_row, 0 }, { last_row, 0 }, {})
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_del_extmark(bufnr, ns_output, m[1])
  end
end

function M.clear_all(bufnr, ns_output)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_output, 0, -1)
end

function M.clear_all_at_row(bufnr, ns_output, row)
  M.clear(bufnr, ns_output, row)
end

return M
