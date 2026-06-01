-- Isolated Neovim config for validating nvim-jupyter "in context".
-- Mirrors Robert's core ~/.config/nvim setup, then adds the local nvim-jupyter
-- checkout. Launched via test/test.sh under NVIM_APPNAME=nvim-jupyter-test, so
-- it never touches the real ~/.config/nvim. Installed plugins and mason are
-- reused read-only (lazy `root` points at the real data dir); only this init
-- and an isolated lazy-lock.json live in the appname dir.
--
-- @@REPO@@ is substituted with the absolute repo path by test/test.sh.

vim.wo.relativenumber = true
vim.opt.guicursor = "n-v-c:block,i-ci-ve:ver25,r-cr:hor20,o:hor50"
vim.opt.clipboard = "unnamedplus"
vim.opt.number = true

-- Visual mode tab to indent, shift-tab to outdent
vim.keymap.set("v", "<Tab>", ">gv", { noremap = true, silent = true })
vim.keymap.set("v", "<S-Tab>", "<gv", { noremap = true, silent = true })

-- Show Errors
vim.keymap.set("n", "<S-e>", function()
  vim.diagnostic.open_float(nil, { focusable = false, scope = "cursor" })
end, { desc = "Show diagnostic under cursor" })

-- Comments
vim.keymap.set("n", "<C-_>", "gcc", { remap = true, desc = "Toggle comment line" })
vim.keymap.set("n", "<C-/>", "gcc", { remap = true, desc = "Toggle comment line" })
vim.keymap.set("v", "<C-_>", "gc", { remap = true, desc = "Toggle comment selection" })
vim.keymap.set("v", "<C-/>", "gc", { remap = true, desc = "Toggle comment selection" })

-- NvimTree toggle
vim.api.nvim_set_keymap("n", "<C-t>", "<ESC>:NvimTreeToggle<CR>", { noremap = true, silent = true })

-- Launch OpenAI
vim.api.nvim_set_keymap("n", "<C-S-g>", "<ESC>:GpChatToggle split<CR>", { noremap = true, silent = true })

-- Source Robert's real Python helpers if present (live in the real config dir).
for _, f in ipairs({ "python_runner.lua", "build.lua" }) do
  local p = vim.fn.expand("~/.config/nvim/" .. f)
  if vim.fn.filereadable(p) == 1 then
    pcall(dofile, p)
  end
end

-- Reuse the real lazy.nvim bootstrap; fall back to a fresh clone if absent.
local real_lazy = vim.fn.expand("~/.config/nvim/lazy/lazy.nvim")
if vim.fn.isdirectory(real_lazy) == 1 then
  vim.opt.rtp:prepend(real_lazy)
else
  local boot = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
  if vim.fn.isdirectory(boot) == 0 then
    vim.fn.system({ "git", "clone", "--filter=blob:none",
      "https://github.com/folke/lazy.nvim.git", "--branch=stable", boot })
  end
  vim.opt.rtp:prepend(boot)
end

local REAL_DATA = vim.fn.expand("~/.local/share/nvim")

local specs = {
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    config = function()
      vim.cmd("colorscheme tokyonight-night")
    end,
  },
  {
    "robitx/gp.nvim",
    config = function()
      require("gp").setup({})
    end,
  },
  -- Mason (LSP installer) — reuse the real mason install dir read-only.
  {
    "williamboman/mason.nvim",
    config = function()
      require("mason").setup({ install_root_dir = REAL_DATA .. "/mason" })
    end,
  },
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = { "williamboman/mason.nvim" },
    config = function()
      require("mason-lspconfig").setup({
        ensure_installed = { "clangd", "pyright", "lemminx", "rust_analyzer", "taplo" },
      })
    end,
  },
  {
    "neovim/nvim-lspconfig",
    dependencies = { "williamboman/mason-lspconfig.nvim" },
    config = function()
      vim.lsp.config("clangd", {
        cmd = { "clangd", "--background-index", "--clang-tidy", "--completion-style=detailed" },
      })
      vim.lsp.config("pyright", {
        settings = {
          python = {
            pythonPath = vim.env.CONDA_PREFIX and (vim.env.CONDA_PREFIX .. "/bin/python") or "python3",
            analysis = {
              autoSearchPaths = true,
              diagnosticMode = "openFilesOnly",
              useLibraryCodeForTypes = true,
            },
          },
        },
      })
      local lemminx_cmd = vim.fn.expand("~/.local/share/nvim/mason/bin/lemminx")
      if vim.fn.executable(lemminx_cmd) == 1 then
        vim.lsp.config("lemminx", {
          cmd = { lemminx_cmd },
          settings = { xml = { validation = { noGrammar = "ignore" } } },
        })
        vim.lsp.enable("lemminx")
      end
      vim.lsp.enable({ "clangd", "pyright", "taplo" })
    end,
  },
  {
    "mrcjkb/rustaceanvim",
    version = "^9",
    lazy = false,
    init = function()
      vim.g.rustaceanvim = {
        server = {
          standalone = false,
          default_settings = {
            ["rust-analyzer"] = {
              cargo = { allFeatures = true },
              check = { command = "clippy" },
            },
          },
        },
      }
    end,
  },
  {
    "mg979/vim-visual-multi",
    branch = "master",
  },
  -- Completion
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "L3MON4D3/LuaSnip",
      "saadparwaiz1/cmp_luasnip",
    },
    config = function()
      local cmp = require("cmp")
      local luasnip = require("luasnip")
      cmp.setup({
        snippet = {
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ["<S-Tab>"] = cmp.mapping.select_prev_item(),
          ["<Tab>"] = cmp.mapping.confirm({ select = true }),
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
          { name = "luasnip" },
        }),
        completion = {
          autocomplete = { require("cmp.types").cmp.TriggerEvent.TextChanged },
          completeopt = "menu,menuone,noinsert",
          keyword_length = 1,
          entries_limit = 3,
        },
      })
      local cmp_autopairs = require("nvim-autopairs.completion.cmp")
      cmp.event:on("confirm_done", cmp_autopairs.on_confirm_done())
    end,
  },
  {
    "numToStr/Comment.nvim",
    event = "VeryLazy",
    config = function()
      require("Comment").setup()
    end,
  },
  {
    "tpope/vim-fugitive",
    config = function()
      vim.keymap.set("n", "<leader>gs", ":Git<CR>", { desc = "Git status" })
    end,
  },
  -- Treesitter
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter.configs").setup({
        ensure_installed = { "lua", "python", "bash", "json", "c", "cpp", "xml", "astro", "rust", "toml" },
        highlight = { enable = true },
        indent = { enable = true, disable = { "c", "cpp", "astro" } },
      })
    end,
  },
  -- File explorer
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("nvim-tree").setup({ view = { width = 45 } })
    end,
  },
  -- Auto-pairing
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    config = function()
      require("nvim-autopairs").setup({})
    end,
  },
  -- XML tag auto-closing
  {
    "windwp/nvim-ts-autotag",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    config = function()
      require("nvim-ts-autotag").setup({
        opts = { enable_close = true, enable_rename = true, enable_close_on_slash = true },
        per_filetype = { xml = { enable_close = true } },
      })
    end,
  },
  {
    "lewis6991/gitsigns.nvim",
    event = "BufReadPre",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      local gitsigns = require("gitsigns")
      vim.api.nvim_create_autocmd("BufWinEnter", {
        callback = function(args)
          local buf = args.buf
          local ft = vim.api.nvim_buf_get_option(buf, "filetype")
          if ft == "fugitive" or ft == "gitcommit" or ft == "diff" then
            gitsigns.attach(buf)
          else
            gitsigns.detach(buf)
          end
        end,
      })
    end,
  },

  -- nvim-gfx (image/video viewer) from the sibling repo, if present locally.
  vim.fn.isdirectory(vim.fn.expand("~/rustprojects/neovim-graphics-viewer")) == 1
      and {
        dir = vim.fn.expand("~/rustprojects/neovim-graphics-viewer"),
        config = function()
          require("nvim-gfx").setup()
        end,
      }
    or nil,

  -- The plugin under test: local nvim-jupyter checkout.
  {
    dir = "@@REPO@@",
    build = "bash build.sh",
    config = function()
      require("nvim-jupyter").setup()
    end,
  },
}

-- Freeze every reused plugin. Combined with the disabled checker/change
-- detection below (no network fetch), `pin = true` means lazy reconciles each
-- spec only against refs ALREADY in the shared real clones — which match what's
-- installed — so any git task is a no-op and ~/.local/share/nvim/lazy is never
-- mutated. Verified: real plugin HEADs are unchanged after running this harness.
-- (The local nvim-jupyter `dir` spec has no git remote, so pin is a no-op there.)
for _, s in ipairs(specs) do
  if type(s) == "table" then
    s.pin = true
  end
end

require("lazy").setup(specs, {
  -- Reuse the real plugin install dir (read-only thanks to pin above), but keep
  -- an isolated lockfile in the appname config dir so the real one is untouched.
  root = REAL_DATA .. "/lazy",
  lockfile = vim.fn.stdpath("config") .. "/lazy-lock.json",
  install = { missing = true },
  -- Don't auto-check for plugin updates in the throwaway test editor.
  checker = { enabled = false },
  change_detection = { enabled = false },
})

-- Open NvimTree when launched on a directory or with no args (matches real config).
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    local first_arg = vim.fn.argv(0)
    local is_dir = first_arg and vim.fn.isdirectory(first_arg) == 1
    if is_dir or #vim.fn.argv() == 0 then
      vim.cmd("enew")
      vim.cmd("NvimTreeToggle")
    end
  end,
})
