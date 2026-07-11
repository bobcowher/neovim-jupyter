local M = {}

function M.select(items, opts, on_choice)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false

  local lines = {}
  for _, item in ipairs(items) do
    table.insert(lines, tostring(item))
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = math.floor(vim.o.columns * 0.7)
  local height = math.min(math.floor(vim.o.lines * 0.7), #items)
  if height < 5 then height = 5 end

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win_opts = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = opts.prompt or "Select",
    title_pos = "center",
    zindex = 150,
  }

  local win = vim.api.nvim_open_win(buf, true, win_opts)
  
  vim.wo[win].cursorline = true

  local function close(choice)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    on_choice(choice)
  end

  local function confirm_and_close()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local idx = cursor[1]
    local choice = items[idx]
    
    if opts.no_confirm then
      close(choice)
      return
    end

    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    
    M.select({ "Yes", "No" }, { prompt = "Start Kernel? " .. tostring(choice), no_confirm = true }, function(ans)
      if ans == "Yes" then
        on_choice(choice)
      else
        on_choice(nil)
      end
    end)
  end

  vim.keymap.set("n", "<CR>", confirm_and_close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", function() close(nil) end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function() close(nil) end, { buffer = buf, nowait = true })

  -- Provide a helpful header for the first launch
  vim.notify("Use j/k to navigate, / to search, and <Enter> to select", vim.log.levels.INFO)
end

return M
