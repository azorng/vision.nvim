local source = debug.getinfo(1, "S").source:sub(2)
local script_path = vim.fs.normalize(vim.fn.fnamemodify(source, ":p"))
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script_path)))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local tests = {}

local function test(name, fn)
  tests[#tests + 1] = {
    name = name,
    fn = fn,
  }
end

local function fail(message)
  error(message, 2)
end

local function eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail((message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
  end
end

local function truthy(value, message)
  if not value then
    fail(message or "expected truthy value")
  end
end

local function tempdir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return vim.fs.normalize(path)
end

local function write_file(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function edit(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

local function exit_visual()
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "xt", false)
  pcall(vim.cmd.redraw)
end

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function rpc_request(transport, token, method)
  local uv = vim.uv or vim.loop
  local client = transport.kind == "socket" and uv.new_pipe(false) or uv.new_tcp()
  local done = false
  local err_msg = nil
  local chunks = {}

  local function finish(err)
    err_msg = err
    done = true
  end

  local function on_read(err, data)
    if err then
      finish(tostring(err))
      return
    end
    if data == nil then
      finish("response ended before newline")
      return
    end
    chunks[#chunks + 1] = data
    if table.concat(chunks):find("\n", 1, true) then
      done = true
    end
  end

  local function on_connect(err)
    if err then
      finish(tostring(err))
      return
    end
    client:read_start(on_read)
    client:write(vim.json.encode({
      id = 1,
      method = method,
      token = token,
      params = {},
    }) .. "\n")
  end

  if transport.kind == "socket" then
    client:connect(transport.path, on_connect)
  else
    client:connect(transport.host, transport.port, on_connect)
  end

  local ok = vim.wait(2000, function()
    return done
  end, 10)
  close_handle(client)

  if not ok then
    fail("rpc request timed out")
  end
  if err_msg then
    fail("rpc request failed: " .. err_msg)
  end

  local line = table.concat(chunks):match("^(.-)\n")
  return vim.json.decode(line)
end

test("capture returns a visual selection attachment", function()
  package.loaded["vision.config"] = nil
  package.loaded["vision.capture"] = nil

  local util = require("vision.util")
  local config = require("vision.config").apply({
    selection = {
      clear_after_send = false,
    },
  })
  local capture = require("vision.capture")
  local dir = tempdir()
  vim.api.nvim_set_current_dir(dir)

  local path = vim.fs.joinpath(dir, "main.lua")
  write_file(path, {
    "alpha",
    "beta",
    "gamma",
  })
  edit(path)
  local expected_path = util.buffer_path(vim.api.nvim_get_current_buf())
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! Vj")

  local envelope = capture.consume(config)
  exit_visual()

  eq(envelope.schema, 1)
  eq(envelope.attachment.type, "visual_selection")
  eq(envelope.attachment.mode, "line")
  eq(envelope.attachment.text, "alpha\nbeta")
  eq(envelope.attachment.range, {
    start_line = 0,
    start_col = 0,
    end_line = 1,
    end_col = 4,
  })
  eq(envelope.context.current_file, expected_path)
end)

test("session service consumes an attachment over rpc", function()
  package.loaded["vision"] = nil
  package.loaded["vision.session"] = nil

  local dir = tempdir()
  local data = vim.fs.joinpath(dir, "data")
  vim.env.VISION_NVIM_DATA_HOME = data
  vim.api.nvim_set_current_dir(dir)

  local path = vim.fs.joinpath(dir, "service.lua")
  write_file(path, {
    "one",
    "two",
    "three",
  })
  edit(path)
  local expected_path = require("vision.util").buffer_path(vim.api.nvim_get_current_buf())
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! Vj")

  local vision = require("vision")
  vision.setup({
    selection = {
      clear_after_send = false,
    },
  })

  local session = require("vision.session")._runtime
  truthy(session.running, "session should start during setup")
  local response = rpc_request(session.transport, session.token, "vision.consume_attachment")
  require("vision.session").stop()
  exit_visual()

  eq(response.id, 1, vim.inspect(response))
  eq(response.error, nil)
  eq(response.result.attachment.text, "one\ntwo")
  eq(response.result.attachment.file, expected_path)
end)

local failures = 0
for _, item in ipairs(tests) do
  local ok, err = xpcall(item.fn, debug.traceback)
  if ok then
    io.stdout:write("ok - " .. item.name .. "\n")
  else
    failures = failures + 1
    io.stderr:write("not ok - " .. item.name .. "\n" .. tostring(err) .. "\n")
  end
end

if failures > 0 then
  vim.cmd(("cquit %d"):format(failures))
else
  vim.cmd("qa!")
end
