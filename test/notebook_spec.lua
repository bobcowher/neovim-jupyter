package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"
package.cpath = package.cpath .. ";" .. (os.getenv("HOME") or "") .. "/.luarocks/lib/lua/5.1/?.so"

do
  _G.vim = {
    json = {
      decode = function(s)
        local ok, cjson = pcall(require, "cjson")
        if ok then return cjson.decode(s) end
        local ok2, dkjson = pcall(require, "dkjson")
        if ok2 then return dkjson.decode(s) end
        error("no JSON library available — install lua-cjson: luarocks install lua-cjson")
      end,
      encode = function(t)
        local ok, cjson = pcall(require, "cjson")
        if ok then return cjson.encode(t) end
        local ok2, dkjson = pcall(require, "dkjson")
        if ok2 then return dkjson.encode(t) end
        error("no JSON library")
      end,
    },
    fn = {
      readfile = function(path)
        local f = assert(io.open(path, "r"))
        local content = f:read("*a")
        f:close()
        local lines = {}
        for line in content:gmatch("([^\n]*)\n?") do
          table.insert(lines, line)
        end
        return lines
      end,
      writefile = function(lines, path)
        local f = assert(io.open(path, "w"))
        f:write(table.concat(lines, "\n"))
        f:close()
      end,
    },
    tbl_deep_extend = function(mode, a, b) return b end,
  }
end

local notebook = require("nvim-jupyter.notebook")

describe("notebook", function()
  local fixture_path = "test/fixtures/simple.ipynb"

  it("parses cell count", function()
    local nb = notebook.load(fixture_path)
    assert.equals(3, #nb.cells)
  end)

  it("parses cell types", function()
    local nb = notebook.load(fixture_path)
    assert.equals("markdown", nb.cells[1].cell_type)
    assert.equals("code", nb.cells[2].cell_type)
    assert.equals("code", nb.cells[3].cell_type)
  end)

  it("parses cell source as string", function()
    local nb = notebook.load(fixture_path)
    assert.truthy(nb.cells[1].source:find("Hello World", 1, true))
    assert.truthy(nb.cells[2].source:find("x = 1 + 1", 1, true))
  end)

  it("parses kernelspec name", function()
    local nb = notebook.load(fixture_path)
    assert.equals("python3", nb.metadata.kernelspec.name)
  end)

  it("round-trips to JSON", function()
    local nb = notebook.load(fixture_path)
    local tmp = os.tmpname() .. ".ipynb"
    notebook.save(nb, tmp)
    local nb2 = notebook.load(tmp)
    assert.equals(#nb.cells, #nb2.cells)
    assert.equals(nb.cells[2].source, nb2.cells[2].source)
    os.remove(tmp)
  end)
end)
