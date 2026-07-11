local M = {}

local state = {
  job_id     = nil,
  handlers   = {},
  stdout_buf = "",
}

local function binary_path()
  local src = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fn.fnamemodify(src, ":h:h:h")
  return root .. "/bin/nvim-jupyter"
end

local function dispatch(event)
  local handlers = state.handlers[event.event] or {}
  for _, fn in ipairs(handlers) do
    fn(event)
  end
  for _, fn in ipairs(state.handlers["*"] or {}) do
    fn(event)
  end
end

local function on_stdout(_, data, _)
  if not data or #data == 0 then return end
  
  data[1] = state.stdout_buf .. data[1]
  state.stdout_buf = data[#data]
  
  for i = 1, #data - 1 do
    local line = data[i]
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == "table" and event.event then
        dispatch(event)
      else
        local snippet = string.sub(line, 1, 150)
        vim.notify("nvim-jupyter: malformed event: " .. snippet .. "...", vim.log.levels.WARN)
      end
    end
  end
end

local function on_exit(_, code, _)
  if code ~= 0 then
    vim.notify("nvim-jupyter: daemon exited with code " .. code, vim.log.levels.WARN)
  end
  state.job_id = nil
  state.stdout_buf = ""
  dispatch({ event = "daemon_died", code = code })
end

function M.ensure_started()
  if state.job_id then return true end
  local bin = binary_path()
  if vim.fn.executable(bin) == 0 then
    vim.notify("nvim-jupyter: binary not found — run :JupyterBuild", vim.log.levels.ERROR)
    return false
  end
  state.job_id = vim.fn.jobstart({ bin }, {
    on_stdout = on_stdout,
    on_exit   = on_exit,
    stdout_buffered = false,
  })
  return state.job_id > 0
end

function M.send(cmd)
  if not state.job_id then return end
  vim.fn.chansend(state.job_id, vim.json.encode(cmd) .. "\n")
end

function M.on(event_type, handler)
  state.handlers[event_type] = state.handlers[event_type] or {}
  table.insert(state.handlers[event_type], handler)
  return handler
end

function M.remove_handler(event_type, handler)
  local list = state.handlers[event_type]
  if not list then return end
  for i, fn in ipairs(list) do
    if fn == handler then
      table.remove(list, i)
      break
    end
  end
end

function M.stop()
  if state.job_id then
    M.send({ cmd = "quit" })
    vim.fn.jobstop(state.job_id)
    state.job_id = nil
  end
end

function M.is_running()
  return state.job_id ~= nil
end

return M
