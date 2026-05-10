local source = debug.getinfo(1, "S").source:sub(2)
local script_path = vim.fs.normalize(vim.fn.fnamemodify(source, ":p"))
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script_path)))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/?.lua",
  root .. "/?/init.lua",
  root .. "/tests/?.lua",
  root .. "/tests/?/init.lua",
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local provider = vim.env.VISION_NVIM_E2E_PROVIDER or "all"
local suites = {}

if provider == "all" or provider == "codex" then
  suites[#suites + 1] = require("tests.e2e.codex")
end
if provider == "all" or provider == "claude" then
  suites[#suites + 1] = require("tests.e2e.claude")
end
if provider == "all" or provider == "opencode" then
  suites[#suites + 1] = require("tests.e2e.opencode")
end
if provider == "all" or provider == "pi" then
  suites[#suites + 1] = require("tests.e2e.pi")
end

local failures = 0
for _, suite in ipairs(suites) do
  local ok, err = xpcall(suite.run, debug.traceback)
  if ok then
    io.stdout:write("ok - " .. suite.name .. "\n")
  else
    failures = failures + 1
    io.stderr:write("not ok - " .. suite.name .. "\n" .. tostring(err) .. "\n")
  end
end

if failures > 0 then
  vim.cmd(("cquit %d"):format(failures))
else
  vim.cmd("qa!")
end
