do
  _G.vim = { api = {}, fn = {}, log = { levels = { WARN = 2 } } }
end
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"
local output = require("nvim-jupyter.output")

describe("output", function()
  it("truncates long output", function()
    local lines = {}
    for i = 1, 100 do table.insert(lines, "line " .. i) end
    local truncated = output._truncate(lines, 10)
    assert.equals(11, #truncated)
    assert.truthy(truncated[11]:find("90 more"))
  end)

  it("does not truncate short output", function()
    local lines = { "a", "b", "c" }
    local result = output._truncate(lines, 50)
    assert.equals(3, #result)
  end)

  it("formats stream text into lines", function()
    local result = output._text_to_lines("hello\nworld\n")
    assert.equals(2, #result)
    assert.equals("hello", result[1])
    assert.equals("world", result[2])
  end)

  it("strips ANSI codes from traceback", function()
    local ansi = "\27[31mValueError\27[0m: bad"
    local stripped = output._strip_ansi(ansi)
    assert.equals("ValueError: bad", stripped)
  end)
end)
