do
  _G.vim = { api = {}, fn = {}, log = { levels = { WARN = 2 } } }
end
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local cells = require("nvim-jupyter.cells")

describe("cells pure logic", function()
  it("cell_lines_from_source splits correctly", function()
    local src = "line1\nline2\nline3"
    local result = cells._split_source_to_lines(src)
    assert.equals(3, #result)
    assert.equals("line1", result[1])
    assert.equals("line3", result[3])
  end)

  it("join_lines_to_source joins with newlines", function()
    local lines = {"a", "b", "c"}
    local src = cells._join_lines_to_source(lines)
    assert.equals("a\nb\nc", src)
  end)
end)
