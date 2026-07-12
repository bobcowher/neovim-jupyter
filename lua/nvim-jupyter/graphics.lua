local M = {}

local images = {}
local ns_images = vim.api.nvim_create_namespace("nvim_jupyter_images")
local image_counter = 50000

local function write_tty(data)
  -- Write to stderr to bypass Neovim's stdout screen renderer
  -- This prevents base64 escape sequences from being interleaved with UI redraws
  pcall(vim.api.nvim_chan_send, vim.v.stderr, data)
end

function M.draw_kitty(id, row, col, b64_data)
  local buf = {}
  table.insert(buf, string.format("\x1b7\x1b[%d;%dH", row, col))
  
  local chunk_size = 4096
  local total_chunks = math.ceil(#b64_data / chunk_size)
  
  for i = 1, total_chunks do
    local offset = (i - 1) * chunk_size + 1
    local chunk = b64_data:sub(offset, offset + chunk_size - 1)
    local m = i < total_chunks and 1 or 0
    
    if i == 1 then
      table.insert(buf, string.format("\x1b_Ga=T,f=100,i=%d,q=2,m=%d;%s\x1b\\", id, m, chunk))
    else
      table.insert(buf, string.format("\x1b_Gm=%d;%s\x1b\\", m, chunk))
    end
  end
  
  table.insert(buf, "\x1b8")
  write_tty(table.concat(buf))
end

function M.clear_kitty(id)
  write_tty(string.format("\x1b_Ga=d,d=i,i=%d\x1b\\", id))
end

function M.clear_all()
  for id, _ in pairs(images) do
    M.clear_kitty(id)
  end
  images = {}
end

function M.show_image(bufnr, anchor_row, b64_data)
  if #b64_data > 3000000 then
    vim.notify("nvim-jupyter: Image is too large to render inline (over 3MB). Use NvimGfx to view.", vim.log.levels.WARN)
    return nil
  end

  -- 20 blank lines to make room for the image
  local height_lines = 20
  local vl = {}
  for i = 1, height_lines do
    table.insert(vl, { { string.rep(" ", 80), "Normal" } })
  end
  
  local ext_id = vim.api.nvim_buf_set_extmark(bufnr, ns_images, anchor_row, 0, {
    virt_lines = vl,
    virt_lines_above = false,
  })
  
  local kitty_id = image_counter
  image_counter = image_counter + 1
  
  images[ext_id] = {
    bufnr = bufnr,
    kitty_id = kitty_id,
    b64_data = b64_data:gsub("%s+", ""), -- strip newlines
    visible = false,
  }
  
  M.redraw()
  return ext_id
end

function M.remove_image(bufnr, ext_id)
  if images[ext_id] then
    M.clear_kitty(images[ext_id].kitty_id)
    images[ext_id] = nil
  end
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_images, ext_id)
end

function M.clear_buffer(bufnr)
  for ext_id, img in pairs(images) do
    if img.bufnr == bufnr then
      M.clear_kitty(img.kitty_id)
      images[ext_id] = nil
    end
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_images, 0, -1)
end

function M.redraw()
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local win_info = vim.fn.getwininfo(winid)[1]
  if not win_info then return end

  for ext_id, img in pairs(images) do
    if img.bufnr == bufnr then
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_images, {0,0}, {-1,-1}, {details=true})
      local found = false
      local row = nil
      for _, m in ipairs(marks) do
        if m[1] == ext_id then
          row = m[2]
          found = true
          break
        end
      end
      
      if found and row then
        local pos = vim.fn.screenpos(winid, row + 1, 1)
        if pos.row > 0 then
          -- Anchor text is visible. Image starts on the next screen row.
          local screen_row = pos.row + 1
          local screen_col = pos.col
          M.draw_kitty(img.kitty_id, screen_row, screen_col, img.b64_data)
          img.visible = true
        else
          -- Anchor text is offscreen. Check if we should clear it.
          if img.visible then
            M.clear_kitty(img.kitty_id)
            img.visible = false
          end
        end
      else
        -- Extmark deleted
        M.clear_kitty(img.kitty_id)
        images[ext_id] = nil
      end
    else
      -- Not in current buffer
      if img.visible then
        M.clear_kitty(img.kitty_id)
        img.visible = false
      end
    end
  end
end

function M.setup()
  local aug = vim.api.nvim_create_augroup("NvimJupyterGraphics", { clear = true })
  vim.api.nvim_create_autocmd({"CursorMoved", "WinScrolled", "WinEnter", "BufEnter", "VimResized"}, {
    group = aug,
    callback = function()
      vim.schedule(M.redraw)
    end
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = aug,
    callback = function() M.clear_all() end
  })
end

return M
