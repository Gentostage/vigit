package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local keymaps = require("vigit.ui.keymaps")
local destination = "docs/keymaps.md"
local generated = keymaps.render_markdown()

local handle = io.open(destination, "rb")
local current = handle and handle:read("*a") or nil
if handle then handle:close() end

if arg[1] == "--check" then
  if current ~= generated then
    io.stderr:write(destination .. " is out of date; run lua scripts/generate-keymaps.lua\n")
    os.exit(1)
  end
  os.exit(0)
end

if arg[1] ~= nil then
  io.stderr:write("usage: lua scripts/generate-keymaps.lua [--check]\n")
  os.exit(2)
end

handle = assert(io.open(destination, "wb"))
handle:write(generated)
handle:close()
