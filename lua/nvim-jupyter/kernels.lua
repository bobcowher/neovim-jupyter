local daemon = require("nvim-jupyter.daemon")

local M = {}

M._state = {}
M._callbacks = {}

function M.register_callback(msg_id, cb)
  M._callbacks[msg_id] = cb
end

local function new_uuid()
  math.randomseed(os.time() + math.random(100000))
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end)
end

local function set_status(bufnr, kernel_id, status)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local s = M._state[bufnr]
  if s and s.kernel_id == kernel_id then
    s.status = status
    vim.b[bufnr].jupyter_kernel_status = status
  end
end

-- Global handlers for lifecycle events
daemon.on("kernels_list", function(ev)
  -- Find the buffer that is currently picking a kernel
  local target_bufnr, target_s
  for bufnr, s in pairs(M._state) do
    if s.status == "picking" then
      target_bufnr, target_s = bufnr, s
      break
    end
  end
  if not target_bufnr then return end
  local s = target_s

  local names = {}
  local current_idx = nil
  for i, k in ipairs(ev.kernels) do
    local display = k.name .. " — " .. k.display_name
    if s.picking_name == k.name then
      display = "★ " .. display
      current_idx = i
    end
    table.insert(names, display)
  end
  if current_idx and current_idx > 1 then
    local current = table.remove(names, current_idx)
    table.insert(names, 1, current)
  end
  if #names == 0 then
    vim.notify("nvim-jupyter: no kernels found — run: pip install ipykernel", vim.log.levels.ERROR)
    return
  end
  require("nvim-jupyter.ui").select(names, { prompt = "Select Jupyter kernel (Current Buffer Scope):" }, function(choice)
    if not choice then return end
    local choice_clean = choice:gsub("^★%s*", "")
    local chosen_name = choice_clean:match("^([^%s]+)")
    s.kernel_name = chosen_name

    local chosen_spec
    for _, k in ipairs(ev.kernels) do
      if k.name == chosen_name then chosen_spec = k break end
    end

    if chosen_spec and chosen_spec.language == "python" and chosen_spec.argv and chosen_spec.argv[1] then
      local py_exe = chosen_spec.argv[1]
      vim.system({ py_exe, "-c", "import ipykernel" }, { text = true }, function(obj)
        vim.schedule(function()
          if obj.code ~= 0 then
            require("nvim-jupyter.ui").select({ "Yes", "No" }, { prompt = "ipykernel is missing in this environment. Install it now?", no_confirm = true }, function(ans)
              if ans == "Yes" then
                vim.api.nvim_echo({{ "Installing ipykernel...", "Normal" }}, false, {})
                vim.system({ py_exe, "-m", "pip", "install", "ipykernel" }, { text = true }, function(install_obj)
                  vim.schedule(function()
                    if install_obj.code == 0 then
                      vim.api.nvim_echo({{ "Installed ipykernel! You can now start the kernel.", "Normal" }}, false, {})
                    else
                      vim.notify("Failed to install ipykernel:\n" .. install_obj.stderr, vim.log.levels.ERROR)
                    end
                  end)
                end)
              end
            end)
          else
            daemon.send({ cmd = "start_kernel", kernel_id = s.kernel_id, kernel_name = chosen_name, cwd = s.cwd })
          end
        end)
      end)
    else
      daemon.send({ cmd = "start_kernel", kernel_id = s.kernel_id, kernel_name = chosen_name, cwd = s.cwd })
    end
  end)
end)
daemon.on("execute_done", function(ev)
  for bufnr, s in pairs(M._state) do
    if s.kernel_id == ev.kernel_id then set_status(bufnr, ev.kernel_id, "idle") end
  end
end)

daemon.on("complete_reply", function(ev)
  local cb = M._callbacks[ev.msg_id]
  if cb then
    cb(ev)
    M._callbacks[ev.msg_id] = nil
  end
end)

daemon.on("inspect_reply", function(ev)
  local cb = M._callbacks[ev.msg_id]
  if cb then
    cb(ev)
    M._callbacks[ev.msg_id] = nil
  end
end)

daemon.on("kernel_started", function(ev)
  for bufnr, s in pairs(M._state) do
    if s.kernel_id == ev.kernel_id then set_status(bufnr, ev.kernel_id, "starting") end
  end
end)

daemon.on("kernel_ready", function(ev)
  for bufnr, s in pairs(M._state) do
    if s.kernel_id == ev.kernel_id then 
      set_status(bufnr, ev.kernel_id, "idle") 
      vim.notify("nvim-jupyter: kernel ready", vim.log.levels.INFO)
    end
  end
end)

daemon.on("kernel_died", function(ev)
  for bufnr, s in pairs(M._state) do
    if s.kernel_id == ev.kernel_id then
      if s.restarting then
        s.restarting = false
        local new_id = new_uuid()
        s.kernel_id = new_id
        daemon.send({ cmd = "start_kernel", kernel_id = new_id, kernel_name = s.kernel_name, cwd = s.cwd })
      else
        set_status(bufnr, ev.kernel_id, "dead")
        vim.notify("nvim-jupyter: kernel died (code " .. ev.code .. ") — use :JupyterRestartKernel", vim.log.levels.WARN)
      end
    end
  end
end)

function M.start(bufnr, kernel_name, cwd, old_name)
  if not daemon.ensure_started() then return end

  local kernel_id = new_uuid()
  M._state[bufnr] = {
    kernel_id       = kernel_id,
    kernel_name     = kernel_name,
    picking_name    = old_name,
    status          = (not kernel_name or kernel_name == "") and "picking" or "starting",
    execution_count = 0,
    cwd             = cwd or vim.fn.getcwd(),
    restarting      = false,
  }
  vim.b[bufnr].jupyter_kernel_status = M._state[bufnr].status

  if not kernel_name or kernel_name == "" then
    daemon.send({ cmd = "list_kernels" })
  else
    daemon.send({ cmd = "start_kernel", kernel_id = kernel_id, kernel_name = kernel_name, cwd = cwd })
  end
end

function M.stop(bufnr)
  local s = M._state[bufnr]
  if not s then return end
  daemon.send({ cmd = "stop_kernel", kernel_id = s.kernel_id })
  M._state[bufnr] = nil
end

function M.restart(bufnr)
  local s = M._state[bufnr]
  if not s then return end
  if s.status == "dead" then
    local new_id = new_uuid()
    s.kernel_id = new_id
    register_handlers(bufnr, new_id)
    daemon.send({ cmd = "start_kernel", kernel_id = new_id, kernel_name = s.kernel_name, cwd = s.cwd })
    set_status(bufnr, new_id, "starting")
    return
  end
  s.restarting = true
  daemon.send({ cmd = "restart_kernel", kernel_id = s.kernel_id })
  set_status(bufnr, s.kernel_id, "starting")
end

function M.interrupt(bufnr)
  local s = M._state[bufnr]
  if not s then return end
  daemon.send({ cmd = "interrupt_kernel", kernel_id = s.kernel_id })
end

function M.pick_kernel(bufnr)
  local s = M._state[bufnr]
  local old_name = s and s.kernel_name or nil
  if s then M.stop(bufnr) end
  M.start(bufnr, nil, s and s.cwd or nil, old_name)
end

function M.new_msg_id()
  return new_uuid()
end

function M.state(bufnr)
  return M._state[bufnr]
end

function M.is_ready(bufnr)
  local s = M._state[bufnr]
  return s and (s.status == "idle" or s.status == "busy")
end

function M.complete(bufnr, msg_id, code, cursor_pos)
  local s = M._state[bufnr]
  if not s then return end
  daemon.send({ cmd = "complete", kernel_id = s.kernel_id, msg_id = msg_id, code = code, cursor_pos = cursor_pos })
end

function M.inspect(bufnr, msg_id, code, cursor_pos, detail_level)
  local s = M._state[bufnr]
  if not s then return end
  daemon.send({ cmd = "inspect", kernel_id = s.kernel_id, msg_id = msg_id, code = code, cursor_pos = cursor_pos, detail_level = detail_level or 0 })
end

function M.set_busy(bufnr)
  local s = M._state[bufnr]
  if s then set_status(bufnr, s.kernel_id, "busy") end
end

function M.set_idle(bufnr)
  local s = M._state[bufnr]
  if s then set_status(bufnr, s.kernel_id, "idle") end
end

return M
