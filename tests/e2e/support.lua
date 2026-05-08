local M = {}

local uv = vim.uv or vim.loop
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))

M.root = root

local function fail(message)
  error(message, 2)
end

function M.truthy(value, message)
  if not value then
    fail(message or "expected truthy value")
  end
end

function M.falsy(value, message)
  if value then
    fail(message or "expected falsy value")
  end
end

function M.eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail((message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
  end
end

function M.mkdir(path)
  local ok = vim.fn.mkdir(path, "p")
  if ok ~= 1 and vim.fn.isdirectory(path) ~= 1 then
    fail("failed to create directory: " .. path)
  end
end

function M.with_tempdir(fn)
  local path = vim.fn.tempname()
  M.mkdir(path)
  path = uv.fs_realpath(path) or vim.fs.normalize(path)

  local ok, result = xpcall(function()
    return fn(path)
  end, debug.traceback)

  vim.fn.delete(path, "rf")
  if not ok then
    error(result)
  end
  return result
end

function M.read_file(path)
  local fd = assert(io.open(path, "r"))
  local data = fd:read("*a")
  fd:close()
  return data
end

function M.write_file(path, content)
  M.mkdir(vim.fs.dirname(path))
  local fd = assert(io.open(path, "w"))
  fd:write(content)
  fd:close()
end

function M.copy_file(source, target)
  M.write_file(target, M.read_file(source))
end

function M.run_command(argv, opts, timeout_ms)
  opts = opts or {}
  return vim.system(argv, {
    cwd = opts.cwd or root,
    env = vim.tbl_extend("force", vim.fn.environ(), opts.env or {}),
    stdin = opts.stdin or "",
    text = true,
  }):wait(timeout_ms or 5000)
end

function M.assert_command_ok(result, label)
  if result.code == 0 then
    return
  end

  fail(table.concat({
    (label or "command") .. " failed with exit code " .. tostring(result.code),
    "stdout:",
    result.stdout or "",
    "stderr:",
    result.stderr or "",
  }, "\n"))
end

function M.combined_output(result)
  return table.concat({ result.stderr or "", result.stdout or "" }, "\n")
end

function M.trimmed_tail(text, max_chars)
  max_chars = max_chars or 4000
  if #text <= max_chars then
    return text
  end
  return text:sub(#text - max_chars + 1)
end

function M.new_token(prefix)
  return ("%s%x"):format(prefix or "VISIONE2E", math.floor(((uv.hrtime and uv.hrtime()) or 0) % 0xffffffff))
end

local function format_stderr(lines)
  local items = {}
  for _, line in ipairs(lines or {}) do
    if type(line) == "string" and line ~= "" then
      items[#items + 1] = line
    end
  end
  return table.concat(items, "\n")
end

function M.start_child(opts)
  local nvim = vim.fn.exepath("nvim")
  M.truthy(type(nvim) == "string" and nvim ~= "", "nvim executable not found")

  local stderr = {}
  local chan = vim.fn.jobstart({ nvim, "--embed", "--headless", "-u", "NONE" }, {
    cwd = opts.cwd,
    env = opts.env,
    rpc = true,
    stderr_buffered = true,
    on_stderr = function(_, data)
      if type(data) == "table" then
        vim.list_extend(stderr, data)
      end
    end,
  })
  M.truthy(type(chan) == "number" and chan > 0, "failed to start embedded nvim")

  local child = {
    chan = chan,
    stderr = stderr,
  }

  function child.exec(lua_code, ...)
    return vim.rpcrequest(chan, "nvim_exec_lua", lua_code, { ... })
  end

  function child.wait_for(lua_code, timeout_ms, interval_ms, ...)
    local args = { ... }
    local last_err = nil
    local ok = vim.wait(timeout_ms or 5000, function()
      local call_ok, result = pcall(vim.rpcrequest, chan, "nvim_exec_lua", lua_code, args)
      if call_ok then
        return not not result
      end
      last_err = result
      return false
    end, interval_ms or 50)

    if ok then
      return true
    end

    local parts = { "timed out waiting for child nvim state" }
    if last_err then
      parts[#parts + 1] = tostring(last_err)
    end
    local stderr_text = format_stderr(stderr)
    if stderr_text ~= "" then
      parts[#parts + 1] = stderr_text
    end
    fail(table.concat(parts, "\n"))
  end

  function child.stop()
    pcall(vim.rpcrequest, chan, "nvim_exec_lua", "vim.cmd('qa!'); return true", {})
    vim.fn.jobwait({ chan }, 5000)
    pcall(vim.fn.jobstop, chan)
  end

  child.exec([[
    local plugin_root, cwd = ...
    vim.opt.runtimepath:prepend(plugin_root)
    package.path = table.concat({
      plugin_root .. "/lua/?.lua",
      plugin_root .. "/lua/?/init.lua",
      package.path,
    }, ";")
    vim.api.nvim_set_current_dir(cwd)
    require("vision").setup()
    return true
  ]], root, opts.workspace_root or opts.cwd)

  child.wait_for([[
    local runtime = require("vision.session")._runtime
    return runtime.running and runtime.record_path ~= nil and runtime.transport ~= nil
  ]], 10000, 50)

  return child
end

function M.seed_unsaved_visual_selection(child, file_path, token)
  return child.exec([[
    local path, selection_token = ...
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({
      "alpha",
      "disk-only-value",
      "omega",
    }, path)

    vim.cmd("edit! " .. vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "alpha",
      selection_token,
      "omega",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys("v$", "xt", false)
    vim.wait(1000, function()
      return vim.api.nvim_get_mode().mode == "v"
    end, 10)

    local envelope = require("vision.capture").consume(require("vision.config").apply({
      selection = {
        clear_after_send = false,
      },
    }))

    return {
      mode = vim.api.nvim_get_mode().mode,
      envelope = envelope,
    }
  ]], file_path, token)
end

return M
