local uv = vim.uv or vim.loop

local M = {}

M.TRUNCATION_SUFFIX = "\n[truncated]"

local function trim(value)
  if type(value) ~= "string" then
    return nil
  end

  local trimmed = vim.trim(value)
  if trimmed == "" then
    return nil
  end

  return trimmed
end

local function normalize_slashes(path)
  return (path:gsub("\\", "/"))
end

local function trim_trailing_separator(path)
  if path == "/" or path:match("^%a:/$") then
    return path
  end

  return (path:gsub("/+$", ""))
end

function M.json_null(value)
  if value == nil then
    return vim.NIL
  end
  return value
end

function M.normalize_path(path, opts)
  local value = trim(path)
  if not value then
    return nil
  end

  local cwd = opts and opts.cwd or nil
  local absolute = value
  if value:sub(1, 1) ~= "/" and not value:match("^%a:[/\\]") then
    absolute = vim.fs.joinpath(cwd or vim.fn.getcwd(), value)
  end

  return trim_trailing_separator(vim.fs.normalize(normalize_slashes(vim.fn.fnamemodify(absolute, ":p"))))
end

function M.current_cwd()
  return M.normalize_path(vim.fn.getcwd())
end

function M.buffer_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("^%a[%w+.-]*://") then
    return nil
  end

  return M.normalize_path(name)
end

function M.buffer_identity(bufnr)
  local path = M.buffer_path(bufnr)
  if not path then
    return nil, nil
  end

  return path, vim.uri_from_fname(path)
end

function M.get_line(bufnr, line)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, line, line + 1, false)
  if not ok or #lines == 0 then
    return ""
  end

  return lines[1]
end

function M.now_ms()
  if uv.gettimeofday then
    return math.floor(uv.gettimeofday() * 1000)
  end

  return math.floor(os.time() * 1000)
end

function M.iso_utc_ms(epoch_ms)
  local value = math.floor(epoch_ms or M.now_ms())
  local seconds = math.floor(value / 1000)
  local millis = value % 1000
  return os.date("!%Y-%m-%dT%H:%M:%S", seconds) .. (".%03dZ"):format(millis)
end

function M.ensure_private_dir(path)
  if vim.fn.mkdir(path, "p") ~= 1 and vim.fn.isdirectory(path) ~= 1 then
    return nil, "failed to create directory: " .. path
  end

  if uv.fs_chmod then
    pcall(uv.fs_chmod, path, 448)
  end

  return true
end

function M.write_file(path, contents)
  local parent = vim.fs.dirname(path)
  local ok, dir_err = M.ensure_private_dir(parent)
  if not ok then
    return nil, dir_err
  end

  local tmp = ("%s.tmp.%d.%d"):format(path, uv.os_getpid(), math.floor((uv.hrtime and uv.hrtime() or 0) % 1000000000))
  local fd, open_err = uv.fs_open(tmp, "w", 384)
  if not fd then
    return nil, open_err
  end

  local wrote, write_err = uv.fs_write(fd, contents, -1)
  pcall(uv.fs_close, fd)
  if not wrote then
    pcall(uv.fs_unlink, tmp)
    return nil, write_err
  end

  local renamed, rename_err = uv.fs_rename(tmp, path)
  if not renamed then
    pcall(uv.fs_unlink, tmp)
    return nil, rename_err
  end

  if uv.fs_chmod then
    pcall(uv.fs_chmod, path, 384)
  end

  return true
end

function M.delete_path(path)
  if not path then
    return true
  end

  local ok, err = uv.fs_unlink(path)
  if ok or (type(err) == "string" and err:find("ENOENT", 1, true)) then
    return true
  end

  return nil, err
end

function M.data_home()
  local env_home = trim(vim.env.VISION_NVIM_DATA_HOME)
  if env_home then
    return M.normalize_path(env_home)
  end

  local sysname = uv.os_uname and uv.os_uname().sysname or ""
  local xdg = trim(vim.env.XDG_DATA_HOME)
  if sysname == "Linux" and xdg then
    return M.normalize_path(vim.fs.joinpath(xdg, "vision.nvim"))
  end

  local home = trim(uv.os_homedir and uv.os_homedir()) or "~"
  return M.normalize_path(vim.fs.joinpath(home, ".local", "share", "vision.nvim"))
end

function M.sessions_dir()
  return vim.fs.joinpath(M.data_home(), "sessions")
end

function M.sockets_dir()
  return vim.fs.joinpath(M.data_home(), "sockets")
end

local ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

function M.random_token(length)
  local count = length or 32
  local bytes
  if uv.random then
    local ok, result = pcall(uv.random, count)
    if ok and type(result) == "string" and #result == count then
      bytes = result
    end
  end

  if not bytes then
    math.randomseed((uv.hrtime and uv.hrtime() or 0) + uv.os_getpid() + os.time())
    local parts = {}
    for index = 1, count do
      parts[index] = string.char(math.random(0, 255))
    end
    bytes = table.concat(parts)
  end

  local chars = {}
  for index = 1, count do
    local pos = (bytes:byte(index) % #ALNUM) + 1
    chars[index] = ALNUM:sub(pos, pos)
  end

  return table.concat(chars)
end

function M.instance_id()
  return vim.fn.sha256(table.concat({
    tostring(uv.os_getpid()),
    tostring(uv.hrtime and uv.hrtime() or os.time()),
    tostring({}),
  }, ":"))
end

function M.truncate_utf8(text, max_bytes)
  if #text <= max_bytes then
    return text, false
  end

  local suffix = M.TRUNCATION_SUFFIX
  local budget = math.max(max_bytes - #suffix, 0)
  local cut = budget

  while cut > 0 do
    local next_byte = text:byte(cut + 1)
    if not next_byte or next_byte < 128 or next_byte > 191 then
      break
    end
    cut = cut - 1
  end

  return text:sub(1, cut) .. suffix, true
end

return M

