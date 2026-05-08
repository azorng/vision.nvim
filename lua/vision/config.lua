local M = {}

local DEFAULTS = {
  selection = {
    clear_after_send = true,
  },
  context = {
    current_file = true,
    cursor = false,
    current_line = false,
    diagnostics = false,
  },
}

M.defaults = vim.deepcopy(DEFAULTS)

local function fail(message)
  error(message, 0)
end

local function boolean(path, value)
  if type(value) ~= "boolean" then
    fail(path .. " must be a boolean")
  end
end

local function merge_known(defaults, opts, path)
  if opts == nil then
    return vim.deepcopy(defaults)
  end
  if type(opts) ~= "table" then
    fail((path or "config") .. " must be a table")
  end

  local result = vim.deepcopy(defaults)
  for key, value in pairs(opts) do
    if defaults[key] == nil then
      fail("unknown config key: " .. (path and (path .. ".") or "") .. key)
    end

    if type(defaults[key]) == "table" then
      result[key] = merge_known(defaults[key], value, (path and (path .. ".") or "") .. key)
    else
      result[key] = value
    end
  end

  return result
end

function M.validate(config)
  boolean("selection.clear_after_send", config.selection.clear_after_send)

  boolean("context.current_file", config.context.current_file)
  boolean("context.cursor", config.context.cursor)
  boolean("context.current_line", config.context.current_line)
  boolean("context.diagnostics", config.context.diagnostics)
end

function M.apply(opts)
  local config = merge_known(DEFAULTS, opts)
  M.validate(config)
  return config
end

return M
