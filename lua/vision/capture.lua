local util = require("vision.util")

local M = {}

local MAX_SELECTION_BYTES = 16384
local MAX_DIAGNOSTICS = 20

local MODES = {
  v = { mode = "char", region_type = "v" },
  V = { mode = "line", region_type = "V" },
  ["\22"] = { mode = "block", region_type = "\22" },
  s = { mode = "char", region_type = "v" },
  S = { mode = "line", region_type = "V" },
  ["\19"] = { mode = "block", region_type = "\22" },
}

local SEVERITY = {
  [vim.diagnostic.severity.ERROR] = "error",
  [vim.diagnostic.severity.WARN] = "warning",
  [vim.diagnostic.severity.INFO] = "information",
  [vim.diagnostic.severity.HINT] = "hint",
}

function M.is_visual_mode(mode)
  return type(mode) == "string" and MODES[mode] ~= nil
end

local function same_position(left, right)
  return left[2] == right[2] and left[3] == right[3] and left[4] == right[4]
end

local function start_col(segment, bufnr)
  local line_length = #util.get_line(bufnr, segment[2] - 1)
  return math.min(math.max(segment[3] - 1, 0), line_length)
end

local function end_col(segment, bufnr)
  local line_length = #util.get_line(bufnr, segment[2] - 1)
  return math.min(math.max(segment[3], 0), line_length)
end

local function current_selection(mode_info, bufnr)
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")
  if start_pos[2] == 0 or end_pos[2] == 0 then
    return nil
  end

  if mode_info.mode ~= "line" and same_position(start_pos, end_pos) then
    local line = math.max(start_pos[2] - 1, 0)
    local col = start_col(start_pos, bufnr)
    return {
      mode = mode_info.mode,
      range = {
        start_line = line,
        start_col = col,
        end_line = line,
        end_col = col,
      },
      text = "",
      selected = false,
      truncated = false,
    }
  end

  local region_opts = { type = mode_info.region_type }
  local text_lines = vim.fn.getregion(start_pos, end_pos, region_opts)
  local positions = vim.fn.getregionpos(start_pos, end_pos, {
    type = mode_info.region_type,
    eol = true,
  })

  if #text_lines == 0 or #positions == 0 then
    return nil
  end

  local text = table.concat(text_lines, "\n")
  local truncated
  text, truncated = util.truncate_utf8(text, MAX_SELECTION_BYTES)

  local first = positions[1][1]
  local last = positions[#positions][2]
  return {
    mode = mode_info.mode,
    range = {
      start_line = first[2] - 1,
      start_col = start_col(first, bufnr),
      end_line = last[2] - 1,
      end_col = end_col(last, bufnr),
    },
    text = text,
    selected = true,
    truncated = truncated,
  }
end

local function collect_diagnostics(bufnr, path)
  local items = {}
  for _, item in ipairs(vim.diagnostic.get(bufnr)) do
    items[#items + 1] = {
      file = path,
      severity = SEVERITY[item.severity] or "information",
      message = tostring(item.message or ""),
      source = util.json_null(item.source),
      code = util.json_null(item.code),
      start_line = math.max(tonumber(item.lnum) or 0, 0),
      start_col = math.max(tonumber(item.col) or 0, 0),
      end_line = math.max(tonumber(item.end_lnum or item.lnum) or 0, 0),
      end_col = math.max(tonumber(item.end_col or item.col) or 0, 0),
    }
  end

  table.sort(items, function(left, right)
    if left.start_line ~= right.start_line then
      return left.start_line < right.start_line
    end
    if left.start_col ~= right.start_col then
      return left.start_col < right.start_col
    end
    if left.severity ~= right.severity then
      return left.severity < right.severity
    end
    return left.message < right.message
  end)

  while #items > MAX_DIAGNOSTICS do
    items[#items] = nil
  end

  return items
end

function M.consume(config)
  local mode = vim.api.nvim_get_mode().mode
  local mode_info = MODES[mode]
  if not mode_info then
    return nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local path, uri = util.buffer_identity(bufnr)
  if not path then
    return nil
  end

  local selection = current_selection(mode_info, bufnr)
  if not selection then
    return nil
  end

  local cwd = util.current_cwd()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local context = config.context

  return {
    schema = 1,
    workspace = {
      cwd = cwd,
      roots = { cwd },
    },
    attachment = {
      type = "visual_selection",
      file = path,
      uri = uri,
      mode = selection.mode,
      range = selection.range,
      text = selection.text,
      selected = selection.selected,
      truncated = selection.truncated,
    },
    context = {
      current_file = util.json_null(context.current_file and util.buffer_path(bufnr) or nil),
      cursor = util.json_null(context.cursor and {
        line = cursor[1] - 1,
        col = cursor[2],
      } or nil),
      current_line = util.json_null(context.current_line and util.get_line(bufnr, cursor[1] - 1) or nil),
      diagnostics = context.diagnostics and collect_diagnostics(bufnr, path) or {},
    },
  }
end

return M
