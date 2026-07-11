local config   = require("nvim-jupyter.config")
local daemon   = require("nvim-jupyter.daemon")
local notebook = require("nvim-jupyter.notebook")
local cells    = require("nvim-jupyter.cells")
local output   = require("nvim-jupyter.output")
local kernels  = require("nvim-jupyter.kernels")
local graphics = require("nvim-jupyter.graphics")

local M = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

-- ── Output ownership ───────────────────────────────────────────────────────
-- Each cell owns at most one output block, stored on the buffer state keyed by
-- the cell's (edit-stable) separator mark id. The block is rendered as a single
-- ns_output extmark anchored to the cell's CURRENT last line, and re-anchored on
-- every edit (see the TextChanged autocmd in open_notebook). This keeps output
-- pinned to the bottom of its cell: typing/`o` always lands above it, re-runs
-- replace rather than duplicate, and edits never strand it mid-buffer.

local function cell_last_row_by_mark(bufnr, mark_id)
  local marks = cells.get_marks(bufnr)
  for i, m in ipairs(marks) do
    if m.id == mark_id then
      local _, end_row = cells.cell_range(bufnr, i)
      if end_row then return end_row - 1 end
    end
  end
  return nil
end

local function reanchor_output(bufnr, mark_id)
  local s = cells._state[bufnr]
  if not s or not s.cell_output then return end
  local entry = s.cell_output[mark_id]
  if not entry then return end
  
  if entry.image_ext then
    graphics.remove_image(bufnr, entry.image_ext)
    entry.image_ext = nil
  end
  if entry.ext then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, s.ns_output, entry.ext)
    entry.ext = nil
  end
  
  local row = cell_last_row_by_mark(bufnr, mark_id)
  if not row then return end

  if entry.lines and #entry.lines > 0 then
    entry.ext = output.set_at(bufnr, s.ns_output, row, entry.lines, entry.hl,
      config.options.max_output_lines, nil)
  end
  if entry.image_png and entry.image_png ~= vim.NIL then
    entry.image_ext = graphics.show_image(bufnr, row, entry.image_png)
  end
end

local function set_cell_output(bufnr, mark_id, opts)
  local s = cells._state[bufnr]
  if not s then return end
  s.cell_output = s.cell_output or {}
  local prev = s.cell_output[mark_id]
  s.cell_output[mark_id] = {
    lines = opts.lines,
    hl = opts.hl,
    image_png = opts.image_png,
    ext = prev and prev.ext or nil,
    image_ext = prev and prev.image_ext or nil,
  }
  reanchor_output(bufnr, mark_id)
end

local function clear_cell_output(bufnr, mark_id)
  local s = cells._state[bufnr]
  if not s or not s.cell_output then return end
  local entry = s.cell_output[mark_id]
  if entry then
    if entry.ext then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, s.ns_output, entry.ext)
    end
    if entry.image_ext then
      graphics.remove_image(bufnr, entry.image_ext)
    end
  end
  s.cell_output[mark_id] = nil
end

local function reanchor_all_output(bufnr)
  local s = cells._state[bufnr]
  if not s or not s.cell_output then return end
  for mark_id, _ in pairs(s.cell_output) do
    reanchor_output(bufnr, mark_id)
  end
end

local function execute_cell(bufnr, target_index, post_hook)
  if not kernels.is_ready(bufnr) then
    local s = kernels.state(bufnr)
    local st = s and s.status or "not started"
    vim.notify("nvim-jupyter: kernel not ready (status: " .. st .. ")", vim.log.levels.WARN)
    return
  end

  local ks = kernels.state(bufnr)
  local index = target_index
  if not index then
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local cell_info = cells.cell_at_row(bufnr, cursor_row)
    if not cell_info then
      vim.notify("nvim-jupyter: cursor not in a cell", vim.log.levels.WARN)
      return
    end
    index = cell_info.index
  end
  
  local source = cells.get_source(bufnr, index)
  local msg_id = kernels.new_msg_id()
  local s = cells._state[bufnr]

  local marks0 = cells.get_marks(bufnr)
  local run_mark_id = marks0[index] and marks0[index].id
  local meta = s and s.cell_meta[run_mark_id]

  if meta and meta.cell_type == "markdown" then
    clear_cell_output(bufnr, run_mark_id)
    return
  end

  local output_lines = {}
  local had_output = false
  local cell_outputs = {}

  clear_cell_output(bufnr, run_mark_id)
  set_cell_output(bufnr, run_mark_id, { lines = { "[*] running..." }, hl = "NvimJupyterRunning" })

  kernels.set_busy(bufnr)
  daemon.send({ cmd = "execute", kernel_id = ks.kernel_id, msg_id = msg_id, code = source })

  local current_image = nil
  local function render(new_lines, hl, image_png)
    had_output = true
    for _, l in ipairs(new_lines or {}) do table.insert(output_lines, l) end
    if image_png and image_png ~= vim.NIL then current_image = image_png end
    set_cell_output(bufnr, run_mark_id, { lines = output_lines, hl = hl, image_png = current_image })
  end

  local function split_text(text)
    local lines = {}
    local remaining = text or ""
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

  local hs = {}
  hs.stream = daemon.on("stream", function(ev)
    if ev.msg_id ~= msg_id then return end
    table.insert(cell_outputs, { output_type = "stream", name = ev.name, text = split_text(ev.text) })
    render(output._text_to_lines(ev.text), "NvimJupyterOutputText", nil)
  end)

  hs.execute_result = daemon.on("execute_result", function(ev)
    if ev.msg_id ~= msg_id then return end
    local data = { ["text/plain"] = split_text(ev.text) }
    if ev.image_png and ev.image_png ~= vim.NIL then data["image/png"] = ev.image_png end
    table.insert(cell_outputs, { output_type = "execute_result", execution_count = ev.execution_count, data = data, metadata = {} })
    render(output._text_to_lines(ev.text), "NvimJupyterOutputText", ev.image_png)
  end)

  hs.execute_error = daemon.on("execute_error", function(ev)
    if ev.msg_id ~= msg_id then return end
    table.insert(cell_outputs, { output_type = "error", ename = ev.ename, evalue = ev.evalue, traceback = ev.traceback or {} })
    local err_lines = { ev.ename .. ": " .. ev.evalue }
    for _, tb in ipairs(ev.traceback or {}) do
      local clean = output._strip_ansi(tb):gsub("\r", "")
      for _, line in ipairs(output._text_to_lines(clean)) do table.insert(err_lines, line) end
    end
    render(err_lines, "NvimJupyterOutputError", nil)
  end)

  hs.execute_done = daemon.on("execute_done", function(ev)
    if ev.msg_id ~= msg_id then return end
    kernels.set_idle(bufnr)
    if not had_output then clear_cell_output(bufnr, run_mark_id) end
    local meta_curr = s and s.cell_meta[run_mark_id]
    if meta_curr then
      meta_curr.execution_count = ks.execution_count
      meta_curr.outputs = cell_outputs
      ks.execution_count = (ks.execution_count or 0) + 1
    end
    daemon.remove_handler("stream", hs.stream)
    daemon.remove_handler("execute_result", hs.execute_result)
    daemon.remove_handler("execute_error", hs.execute_error)
    daemon.remove_handler("execute_done", hs.execute_done)
    if post_hook then post_hook(index) end
  end)
end

local ns_md = vim.api.nvim_create_namespace("nvim_jupyter_markdown")

local function render_markdown_cells(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_md, 0, -1)
  
  if vim.api.nvim_get_mode().mode:sub(1,1) == "i" then return end

  local marks = cells.get_marks(bufnr)
  for i, mark in ipairs(marks) do
    if mark.meta and mark.meta.cell_type == "markdown" then
      local start_row, end_row = cells.cell_range(bufnr, i)
      local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
      
      for r, line in ipairs(lines) do
        local row = start_row + r - 1
        
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_md, row, 0, {
          end_row = row,
          end_col = #line,
          hl_group = "Comment",
          priority = 200,
          strict = false,
        })
        
        local h_level, title = line:match("^(#+)%s*(.*)$")
        if h_level and title then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_md, row, 0, {
            end_row = row,
            end_col = #h_level + 1,
            conceal = "",
            priority = 201,
            strict = false,
          })
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_md, row, #h_level + 1, {
            end_row = row,
            end_col = #line,
            hl_group = "Title",
            priority = 201,
            strict = false,
          })
        end
      end
    end
  end
end

local function open_notebook(path)
  path = vim.fn.fnamemodify(path, ":p")
  local ok, nb = pcall(notebook.load, path)
  if not ok then
    vim.notify("nvim-jupyter: failed to parse " .. path .. ": " .. nb, vim.log.levels.ERROR)
    return
  end

  local lines, cell_starts = notebook.to_buffer_lines(nb)

  -- Workaround for Neovim's missing virt_lines_above on row 0 bug:
  -- Inject a blank row at the very top so the first cell starts at row 1.
  -- This blank line is automatically stripped out when saving.
  table.insert(lines, 1, "")
  for i = 1, #cell_starts do
    cell_starts[i] = cell_starts[i] + 1
  end

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buftype  = "acwrite"
  vim.bo[bufnr].filetype = "python"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_name(bufnr, path)

  -- Markdown rendering is handled by extmarks now
  vim.opt_local.conceallevel = 2
  vim.opt_local.concealcursor = "nc"

  cells.init(bufnr, nb, lines, cell_starts)

  for i, mark in ipairs(cells.get_marks(bufnr)) do
    if mark.meta and mark.meta.outputs then
      local output_lines = {}
      local current_image = nil
      local has_error = false
      for _, out in ipairs(mark.meta.outputs) do
        if out.output_type == "stream" then
           local full_text = type(out.text) == "table" and table.concat(out.text, "") or (out.text or "")
           for _, l in ipairs(output._text_to_lines(full_text)) do table.insert(output_lines, l) end
        elseif out.output_type == "execute_result" or out.output_type == "display_data" then
           if out.data and out.data["text/plain"] then
             local full_text = type(out.data["text/plain"]) == "table" and table.concat(out.data["text/plain"], "") or out.data["text/plain"]
             for _, l in ipairs(output._text_to_lines(full_text)) do table.insert(output_lines, l) end
           end
           if out.data and out.data["image/png"] then
             current_image = out.data["image/png"]
           end
        elseif out.output_type == "error" then
           has_error = true
           table.insert(output_lines, (out.ename or "Error") .. ": " .. (out.evalue or ""))
           for _, tb in ipairs(out.traceback or {}) do
              local clean = output._strip_ansi(tb):gsub("\r", "")
              for _, line in ipairs(output._text_to_lines(clean)) do
                table.insert(output_lines, line)
              end
           end
        end
      end
      if #output_lines > 0 or current_image then
         set_cell_output(bufnr, mark.id, {
           lines = output_lines,
           hl = has_error and "NvimJupyterOutputError" or "NvimJupyterOutputText",
           image_png = current_image
         })
      end
    end
  end

  -- Keep each cell's output pinned to its current last line as the buffer is
  -- edited (typing, `o`, inserted/removed cells). Without this, output stays at
  -- the row it was rendered at and drifts into the middle of the cell.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    buffer   = bufnr,
    callback = function()
      reanchor_all_output(bufnr)
      render_markdown_cells(bufnr)
    end,
    desc     = "nvim-jupyter: render markdown and keep cell output anchored",
  })
  
  vim.api.nvim_create_autocmd({ "InsertEnter" }, {
    buffer = bufnr,
    callback = function()
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_md, 0, -1)
    end,
    desc     = "nvim-jupyter: unrender markdown for raw editing",
  })
  
  -- Prevent the cursor from landing on the fake row 0
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = bufnr,
    callback = function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      if cursor[1] == 1 then
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
      end
    end,
    desc     = "nvim-jupyter: prevent cursor on fake padding line",
  })

  render_markdown_cells(bufnr)

  local kernel_name = (nb.metadata.kernelspec or {}).name
  local cwd = vim.fn.fnamemodify(path, ":h")
  kernels.start(bufnr, kernel_name, cwd)

  apply_keymaps(bufnr)
end

function apply_keymaps(bufnr)
  if config.options.keymaps == false then return end
  local km = config.options.keymap
  local o = { noremap = true, silent = true, buffer = bufnr }

  if km.execute_advance ~= false then
    vim.keymap.set({ "n", "i" }, km.execute_advance, function()
      vim.cmd("stopinsert")
      execute_cell(bufnr, nil, function(index)
        local mark_count = #cells.get_marks(bufnr)
        if index >= mark_count then cells.add_cell_below(bufnr, index) end
        local ms = cells.get_marks(bufnr)
        if ms[index + 1] then vim.api.nvim_win_set_cursor(0, { ms[index + 1].row + 1, 0 }) end
      end)
    end, vim.tbl_extend("force", o, { desc = "Execute cell + advance" }))
  end

  if km.execute ~= false then
    vim.keymap.set({ "n", "i" }, km.execute, function()
      vim.cmd("stopinsert")
      execute_cell(bufnr, nil)
    end, vim.tbl_extend("force", o, { desc = "Execute cell in place" }))
  end

  if km.execute_insert ~= false then
    vim.keymap.set({ "n", "i" }, km.execute_insert, function()
      vim.cmd("stopinsert")
      execute_cell(bufnr, nil, function(index)
        local new_i = cells.add_cell_below(bufnr, index)
        local ms = cells.get_marks(bufnr)
        if ms[new_i] then
          vim.api.nvim_win_set_cursor(0, { ms[new_i].row + 1, 0 })
          vim.cmd("startinsert")
        end
      end)
    end, vim.tbl_extend("force", o, { desc = "Execute cell + insert below" }))
  end

  if km.next_cell ~= false then
    vim.keymap.set("n", km.next_cell, function()
      local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell_info = cells.cell_at_row(bufnr, cursor_row)
      if not cell_info then return end
      local next_marks = cells.get_marks(bufnr)
      local next = next_marks[cell_info.index + 1]
      if next then vim.api.nvim_win_set_cursor(0, { next.row + 1, 0 }) end
    end, vim.tbl_extend("force", o, { desc = "Next cell" }))
  end

  if km.prev_cell ~= false then
    vim.keymap.set("n", km.prev_cell, function()
      local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell_info = cells.cell_at_row(bufnr, cursor_row)
      if not cell_info then return end
      local prev_marks = cells.get_marks(bufnr)
      local prev = prev_marks[cell_info.index - 1]
      if prev then pcall(vim.api.nvim_win_set_cursor, 0, { prev.row + 1, 0 }) end
    end, vim.tbl_extend("force", o, { desc = "Previous cell" }))
  end

  vim.keymap.set("n", "dd", function()
    if vim.v.count > 0 then return "dd" end
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local cell_info = cells.cell_at_row(bufnr, cursor_row)
    if cell_info then
      local start_row, end_row = cells.cell_range(bufnr, cell_info.index)
      if end_row - start_row == 1 then
        local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
        if lines[1] == "" then
          return "<cmd>lua require('nvim-jupyter.cells').delete_cell(" .. bufnr .. ", " .. cell_info.index .. ")<CR>"
        else
          return "<cmd>lua vim.cmd('normal! yy'); vim.api.nvim_set_current_line('')<CR>"
        end
      end
    end
    return "dd"
  end, vim.tbl_extend("force", o, { expr = true, replace_keycodes = true, desc = "Context-aware delete (line or cell)" }))

  if km.delete_cell ~= false then
    vim.keymap.set("n", km.delete_cell, function()
      local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell_info = cells.cell_at_row(bufnr, cursor_row)
      if not cell_info then return end
      cells.delete_cell(bufnr, cell_info.index)
      vim.notify("nvim-jupyter: cell deleted", vim.log.levels.INFO)
    end, vim.tbl_extend("force", o, { desc = "Delete cell" }))
  end

  if km.toggle_cell_type ~= false then
    vim.keymap.set("n", km.toggle_cell_type, function()
      local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell_info = cells.cell_at_row(bufnr, cursor_row)
      if not cell_info then return end
      cells.toggle_cell_type(bufnr, cell_info.index)
      render_markdown_cells(bufnr)
      vim.notify("nvim-jupyter: toggled cell type", vim.log.levels.INFO)
    end, vim.tbl_extend("force", o, { desc = "Toggle cell type code/markdown" }))
  end
end

function M.setup(opts)
  config.setup(opts)
  graphics.setup()

  vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern  = "*.ipynb",
    callback = function(ev) open_notebook(ev.file) end,
    desc     = "nvim-jupyter: open .ipynb as virtual cell buffer",
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    pattern  = "*.ipynb",
    callback = function(ev)
      local bufnr = vim.api.nvim_get_current_buf()
      local path  = ev.file
      local s     = cells._state[bufnr]
      if not s then return end

      local nb_cells = cells.to_notebook_cells(bufnr)
      local ks = kernels.state(bufnr)
      local meta = ks and { kernelspec = { name = ks.kernel_name or "python3",
                                           display_name = "Python 3", language = "python" } }
                       or {}
      local nb = { nbformat = 4, nbformat_minor = 5, metadata = meta, cells = nb_cells }
      local ok, err = pcall(notebook.save, nb, path)
      if ok then
        vim.bo[bufnr].modified = false
        vim.notify("nvim-jupyter: saved " .. path, vim.log.levels.INFO)
      else
        vim.notify("nvim-jupyter: save failed: " .. err, vim.log.levels.ERROR)
      end
    end,
    desc = "nvim-jupyter: serialize cells back to .ipynb on :w",
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() daemon.stop() end,
    desc     = "nvim-jupyter: stop Rust daemon on exit",
  })

  vim.api.nvim_create_user_command("JupyterExecute", function()
    local bufnr = vim.api.nvim_get_current_buf()
    execute_cell(bufnr, nil)
  end, { desc = "Execute current cell in place" })

  vim.api.nvim_create_user_command("JupyterExecuteAndAdvance", function()
    local bufnr = vim.api.nvim_get_current_buf()
    execute_cell(bufnr, nil, function(index)
      local mark_count = #cells.get_marks(bufnr)
      if index >= mark_count then cells.add_cell_below(bufnr, index) end
      local ms = cells.get_marks(bufnr)
      if ms[index + 1] then vim.api.nvim_win_set_cursor(0, { ms[index + 1].row + 1, 0 }) end
    end)
  end, { desc = "Execute cell + advance to next" })

  vim.api.nvim_create_user_command("JupyterExecuteAndInsert", function()
    local bufnr = vim.api.nvim_get_current_buf()
    execute_cell(bufnr, nil, function(index)
      local new_i = cells.add_cell_below(bufnr, index)
      local ms = cells.get_marks(bufnr)
      if ms[new_i] then vim.api.nvim_win_set_cursor(0, { ms[new_i].row + 1, 0 }) end
    end)
  end, { desc = "Execute cell + insert new below" })

  vim.api.nvim_create_user_command("JupyterExecuteAll", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local marks = cells.get_marks(bufnr)
    for i = 1, #marks do
      execute_cell(bufnr, i)
    end
  end, { desc = "Execute all cells top to bottom" })

  vim.api.nvim_create_user_command("JupyterExecuteAbove", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, cursor_row)
    if not info then return end
    for i = 1, info.index - 1 do
      execute_cell(bufnr, i)
    end
  end, { desc = "Execute all cells above current" })

  vim.api.nvim_create_user_command("JupyterExecuteBelow", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, cursor_row)
    if not info then return end
    local marks = cells.get_marks(bufnr)
    for i = info.index, #marks do
      execute_cell(bufnr, i)
    end
  end, { desc = "Execute current cell and all below" })

  vim.api.nvim_create_user_command("JupyterNextCell", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if not info then return end
    local ms = cells.get_marks(bufnr)
    if ms[info.index + 1] then vim.api.nvim_win_set_cursor(0, { ms[info.index + 1].row + 1, 0 }) end
  end, { desc = "Move to next cell" })

  vim.api.nvim_create_user_command("JupyterPrevCell", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if not info then return end
    local ms = cells.get_marks(bufnr)
    if ms[info.index - 1] then vim.api.nvim_win_set_cursor(0, { ms[info.index - 1].row + 1, 0 }) end
  end, { desc = "Move to previous cell" })

  vim.api.nvim_create_user_command("JupyterAddCellBelow", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if info then cells.add_cell_below(bufnr, info.index) end
  end, { desc = "Add code cell below current" })

  vim.api.nvim_create_user_command("JupyterAddCellAbove", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if info then cells.add_cell_above(bufnr, info.index) end
  end, { desc = "Add code cell above current" })

  vim.api.nvim_create_user_command("JupyterDeleteCell", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if info then cells.delete_cell(bufnr, info.index) end
  end, { desc = "Delete current cell" })

  vim.api.nvim_create_user_command("JupyterChangeCellType", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if info then
      cells.toggle_cell_type(bufnr, info.index)
      render_markdown_cells(bufnr)
    end
  end, { desc = "Toggle cell type code/markdown" })

  vim.api.nvim_create_user_command("JupyterKernel", function()
    local bufnr = vim.api.nvim_get_current_buf()
    kernels.pick_kernel(bufnr)
  end, { desc = "Show kernel picker" })

  vim.api.nvim_create_user_command("JupyterRestartKernel", function()
    local bufnr = vim.api.nvim_get_current_buf()
    kernels.restart(bufnr)
  end, { desc = "Restart kernel" })

  vim.api.nvim_create_user_command("JupyterInterrupt", function()
    local bufnr = vim.api.nvim_get_current_buf()
    kernels.interrupt(bufnr)
  end, { desc = "Interrupt kernel (SIGINT)" })

  vim.api.nvim_create_user_command("JupyterKernelStatus", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local s = kernels.state(bufnr)
    local status = s and s.status or "not started"
    vim.notify("nvim-jupyter kernel: " .. status, vim.log.levels.INFO)
  end, { desc = "Print kernel status" })

  vim.api.nvim_create_user_command("JupyterShowOutput", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if not info then return end
    local _, end_row = cells.cell_range(bufnr, info.index)
    local s = cells._state[bufnr]
    if not s then return end
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, s.ns_output,
      { end_row - 1, 0 }, { end_row - 1, 0 }, { details = true })
    if #marks == 0 then
      vim.notify("nvim-jupyter: no output for current cell", vim.log.levels.INFO)
      return
    end
    local details = marks[1][4]
    local lines = {}
    if details and details.virt_lines then
      for _, vl in ipairs(details.virt_lines) do
        if vl[1] then table.insert(lines, vl[1][1]:sub(3)) end
      end
    end
    vim.cmd("new")
    local out_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, lines)
    vim.bo[out_buf].buftype  = "nofile"
    vim.bo[out_buf].filetype = "text"
    vim.bo[out_buf].modifiable = false
  end, { desc = "Show full cell output in scratch split" })

  vim.api.nvim_create_user_command("JupyterBuild", function()
    local root = plugin_root()
    local cmd  = string.format("cd %s && bash build.sh", vim.fn.shellescape(root))
    vim.notify("nvim-jupyter: building...", vim.log.levels.INFO)
    vim.fn.jobstart({ "sh", "-c", cmd }, {
      on_exit = function(_, code)
        if code == 0 then
          vim.notify("nvim-jupyter: build complete", vim.log.levels.INFO)
        else
          vim.notify("nvim-jupyter: build failed (code " .. code .. ")", vim.log.levels.ERROR)
        end
      end,
    })
  end, { desc = "Build nvim-jupyter Rust binary" })
end

return M
