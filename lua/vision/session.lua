local util = require("vision.util")
local uv = vim.uv or vim.loop

local M = {}

local HOST = "127.0.0.1"
local PORT_MIN = 10000
local PORT_MAX = 65535
local MAX_SOCKET_PATH_BYTES = 100

local runtime = {
  id = util.instance_id(),
  started_at = util.iso_utc_ms(),
  callbacks = nil,
  token = nil,
  handle = nil,
  clients = {},
  transport = nil,
  record_path = nil,
  running = false,
  last_error = nil,
  last_visual_at = nil,
  visual_active = false,
  visual_key = nil,
}

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function remove_client(client)
  runtime.clients[client] = nil
  close_handle(client)
end

local function response(id, result, err)
  if err then
    return {
      id = id or vim.NIL,
      error = err,
    }
  end

  return {
    id = id or vim.NIL,
    result = result == nil and vim.NIL or result,
  }
end

local function decode_request(line)
  local trimmed = line:gsub("\r$", "")
  local ok, decoded = pcall(vim.json.decode, trimmed)
  if not ok or type(decoded) ~= "table" or vim.islist(decoded) then
    return nil, response(nil, nil, {
      code = "invalid_request",
      message = "request must be a JSON object",
    })
  end

  if type(decoded.method) ~= "string" or decoded.method == "" then
    return nil, response(decoded.id, nil, {
      code = "invalid_request",
      message = "method must be a non-empty string",
    })
  end

  return decoded
end

local function dispatch(line)
  local request, err_response = decode_request(line)
  if not request then
    return err_response
  end

  local provided = request.token or request.auth_token
  if type(runtime.token) ~= "string" or provided ~= runtime.token then
    return response(request.id, nil, {
      code = "unauthorized",
      message = "invalid token",
    })
  end

  if request.method == "vision.consume_attachment" then
    local consume = runtime.callbacks and runtime.callbacks.consume_attachment
    if type(consume) ~= "function" then
      return response(request.id, nil)
    end

    local ok, result = xpcall(consume, debug.traceback)
    if not ok then
      return response(request.id, nil, {
        code = "internal_error",
        message = result,
      })
    end

    return response(request.id, result)
  end

  if request.method == "vision.visual_state" then
    local visual_state = runtime.callbacks and runtime.callbacks.visual_state
    if type(visual_state) ~= "function" then
      return response(request.id, nil)
    end

    local ok, result = xpcall(visual_state, debug.traceback)
    if not ok then
      return response(request.id, nil, {
        code = "internal_error",
        message = result,
      })
    end

    return response(request.id, result)
  end

  return response(request.id, nil, {
    code = "method_not_found",
    message = "unknown method: " .. request.method,
  })
end

local function write_response(client, payload)
  if client:is_closing() then
    return
  end

  client:write(vim.json.encode(payload) .. "\n", function()
    remove_client(client)
  end)
end

local function handle_client(client)
  local state = {
    buffer = "",
    done = false,
  }
  runtime.clients[client] = true

  client:read_start(function(err, data)
    if state.done then
      return
    end

    if err then
      state.done = true
      vim.schedule(function()
        write_response(client, response(nil, nil, {
          code = "invalid_request",
          message = "failed to read request",
        }))
      end)
      return
    end

    if data == nil then
      state.done = true
      pcall(client.read_stop, client)
      vim.schedule(function()
        write_response(client, response(nil, nil, {
          code = "invalid_request",
          message = "request must be newline terminated",
        }))
      end)
      return
    end

    state.buffer = state.buffer .. data
    local newline = state.buffer:find("\n", 1, true)
    if not newline then
      return
    end

    state.done = true
    pcall(client.read_stop, client)
    local line = state.buffer:sub(1, newline - 1)
    vim.schedule(function()
      write_response(client, dispatch(line))
    end)
  end)
end

local function listen(handle, kind)
  local ok, err = handle:listen(128, function(listen_err)
    if listen_err then
      return
    end

    local client = kind == "socket" and uv.new_pipe(false) or uv.new_tcp()
    if not client then
      return
    end

    local accepted = handle:accept(client)
    if not accepted then
      close_handle(client)
      return
    end

    handle_client(client)
  end)

  if not ok then
    return nil, err
  end

  return true
end

local function socket_supported()
  local sysname = uv.os_uname and uv.os_uname().sysname or ""
  return sysname ~= "Windows_NT" and uv.new_pipe ~= nil
end

local function bind_socket()
  local ok, err = util.ensure_private_dir(util.sockets_dir())
  if not ok then
    return nil, nil, err
  end

  local path = vim.fs.joinpath(util.sockets_dir(), runtime.id .. ".sock")
  if #path > MAX_SOCKET_PATH_BYTES then
    return nil, nil, "socket path is too long"
  end

  util.delete_path(path)

  local handle = uv.new_pipe(false)
  if not handle then
    return nil, nil, "failed to create socket listener"
  end

  local bound, bind_err = handle:bind(path)
  if not bound then
    close_handle(handle)
    return nil, nil, bind_err
  end

  local listening, listen_err = listen(handle, "socket")
  if not listening then
    close_handle(handle)
    util.delete_path(path)
    return nil, nil, listen_err
  end

  return handle, {
    kind = "socket",
    path = path,
  }
end

local function bind_tcp()
  for port = PORT_MIN, PORT_MAX do
    local handle = uv.new_tcp()
    if handle then
      local bound = handle:bind(HOST, port)
      if bound then
        local listening = listen(handle, "tcp")
        if listening then
          return handle, {
            kind = "tcp",
            host = HOST,
            port = port,
          }
        end
      end
      close_handle(handle)
    end
  end

  return nil, nil, "failed to bind TCP listener"
end

local function bind_listener()
  if socket_supported() then
    local handle, transport = bind_socket()
    if handle then
      return handle, transport
    end
  end

  return bind_tcp()
end

local function session_record()
  local cwd = util.current_cwd()

  return {
    schema = 1,
    id = runtime.id,
    pid = uv.os_getpid(),
    cwd = cwd,
    roots = { cwd },
    transport = vim.deepcopy(runtime.transport),
    token = runtime.token,
    started_at = runtime.started_at,
    last_visual_at = util.json_null(runtime.last_visual_at),
    visual_active = runtime.visual_active,
  }
end

local function publish()
  if not runtime.running then
    return nil, "session is not running"
  end

  local path = vim.fs.joinpath(util.sessions_dir(), runtime.id .. ".json")
  local ok, err = util.write_file(path, vim.json.encode(session_record()) .. "\n")
  if not ok then
    runtime.last_error = err
    return nil, err
  end

  runtime.record_path = path
  runtime.last_error = nil
  return true
end

function M.start(callbacks)
  if runtime.running then
    return true
  end

  runtime.callbacks = callbacks or {}
  runtime.token = util.random_token(32)

  local handle, transport, err = bind_listener()
  if not handle then
    runtime.last_error = err
    return nil, err
  end

  runtime.handle = handle
  runtime.transport = transport
  runtime.running = true
  runtime.last_error = nil
  runtime.last_visual_at = nil
  runtime.visual_active = false
  runtime.visual_key = nil

  local ok, publish_err = publish()
  if not ok then
    M.stop()
    runtime.last_error = publish_err
    return nil, publish_err
  end

  return true
end

function M.stop()
  if not runtime.running and not runtime.handle then
    return true
  end

  runtime.running = false

  for client in pairs(runtime.clients) do
    close_handle(client)
    runtime.clients[client] = nil
  end

  close_handle(runtime.handle)
  runtime.handle = nil

  util.delete_path(runtime.record_path)
  runtime.record_path = nil

  if runtime.transport and runtime.transport.kind == "socket" then
    util.delete_path(runtime.transport.path)
  end

  runtime.transport = nil
  runtime.visual_active = false
  runtime.visual_key = nil
  return true
end

function M.is_running()
  return runtime.running
end

function M.mark_visual_activity(key)
  if not runtime.running then
    return nil, "session is not running"
  end

  if key ~= nil and runtime.visual_active and runtime.visual_key == key then
    return true
  end

  runtime.last_visual_at = util.iso_utc_ms()
  runtime.visual_active = true
  runtime.visual_key = key
  return publish()
end

function M.clear_visual_activity()
  if not runtime.running or (not runtime.visual_active and runtime.visual_key == nil) then
    return true
  end

  runtime.visual_active = false
  runtime.visual_key = nil
  return publish()
end

M._runtime = runtime

return M
