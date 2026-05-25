local daemon = require("nvim-jupyter.daemon")

local M = {}

M._state = {}

local function new_uuid()
  local handle = io.popen("uuidgen")
  local result = handle:read("*a"):gsub("%s+", "")
  handle:close()
  return result
end

local function set_status(bufnr, status)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  M._state[bufnr].status = status
  vim.b[bufnr].jupyter_kernel_status = status
end

local function register_handlers(bufnr, kernel_id)
  local s = M._state[bufnr]

  daemon.on("kernel_started", function(ev)
    if ev.kernel_id ~= kernel_id then return end
    set_status(bufnr, "starting")
  end)

  daemon.on("kernel_ready", function(ev)
    if ev.kernel_id ~= kernel_id then return end
    set_status(bufnr, "idle")
    vim.notify("nvim-jupyter: kernel ready", vim.log.levels.INFO)
  end)

  daemon.on("kernel_died", function(ev)
    if ev.kernel_id ~= kernel_id then return end
    set_status(bufnr, "dead")
    vim.notify("nvim-jupyter: kernel died (code " .. ev.code .. ") — use :JupyterRestartKernel", vim.log.levels.WARN)
  end)

  daemon.on("kernels_list", function(ev)
    if s.status ~= "picking" then return end
    local names = {}
    for _, k in ipairs(ev.kernels) do
      table.insert(names, k.name .. " — " .. k.display_name)
    end
    if #names == 0 then
      vim.notify("nvim-jupyter: no kernels found — run: pip install ipykernel", vim.log.levels.ERROR)
      return
    end
    vim.ui.select(names, { prompt = "Select Jupyter kernel:" }, function(choice)
      if not choice then return end
      local chosen_name = choice:match("^([^%s]+)")
      s.kernel_name = chosen_name
      daemon.send({ cmd = "start_kernel", kernel_id = kernel_id, kernel_name = chosen_name, cwd = s.cwd })
    end)
  end)
end

function M.start(bufnr, kernel_name, cwd)
  if not daemon.ensure_started() then return end

  local kernel_id = new_uuid()
  M._state[bufnr] = {
    kernel_id       = kernel_id,
    kernel_name     = kernel_name,
    status          = "starting",
    execution_count = 0,
    cwd             = cwd or vim.fn.getcwd(),
  }
  vim.b[bufnr].jupyter_kernel_status = "starting"

  register_handlers(bufnr, kernel_id)

  if kernel_name then
    daemon.send({ cmd = "start_kernel", kernel_id = kernel_id, kernel_name = kernel_name, cwd = cwd })
  else
    M._state[bufnr].status = "picking"
    daemon.send({ cmd = "list_kernels" })
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
  daemon.send({ cmd = "restart_kernel", kernel_id = s.kernel_id })
  set_status(bufnr, "starting")
end

function M.interrupt(bufnr)
  local s = M._state[bufnr]
  if not s then return end
  daemon.send({ cmd = "interrupt_kernel", kernel_id = s.kernel_id })
end

function M.pick_kernel(bufnr)
  local s = M._state[bufnr]
  if not s then return end
  M.stop(bufnr)
  M.start(bufnr, nil, s.cwd)
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

function M.set_busy(bufnr)
  set_status(bufnr, "busy")
end

function M.set_idle(bufnr)
  set_status(bufnr, "idle")
end

return M
