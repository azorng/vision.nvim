local capture = require("vision.capture")
local config = require("vision.config")
local session = require("vision.session")
local util = require("vision.util")

local M = {}

local ESC = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
local LIFECYCLE_GROUP = "vision.nvim.lifecycle"
local ACTIVITY_GROUP = "vision.nvim.activity"

local source = debug.getinfo(1, "S").source:sub(2)
local init_path = vim.fs.normalize(vim.fn.fnamemodify(source, ":p"))
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(init_path)))

local current_config = config.apply()
local providers = { "claude", "codex", "opencode", "pi" }
local provider_set = {}
for _, provider in ipairs(providers) do
  provider_set[provider] = true
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, {
    title = "vision.nvim",
  })
end

local function clear_visual_selection()
  if not capture.is_visual_mode(vim.api.nvim_get_mode().mode) then
    return
  end

  vim.api.nvim_feedkeys(ESC, "xt", false)
  pcall(vim.cmd.redraw)
end

local function visual_activity_key(mode)
  if not capture.is_visual_mode(mode) then
    return nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local path = util.buffer_path(bufnr) or ("buffer:" .. tostring(bufnr))
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")

  return table.concat({
    mode,
    path,
    tostring(vim.api.nvim_buf_get_changedtick(bufnr)),
    tostring(start_pos[2]),
    tostring(start_pos[3]),
    tostring(start_pos[4]),
    tostring(end_pos[2]),
    tostring(end_pos[3]),
    tostring(end_pos[4]),
  }, ":")
end

local function install_provider(provider)
  provider = vim.trim(provider or "")
  if not provider_set[provider] then
    return nil, "unknown provider: " .. provider
  end

  local visionctl = vim.fs.joinpath(plugin_root, "bin", "visionctl")
  if vim.fn.executable(visionctl) ~= 1 then
    return nil, "visionctl is not executable: " .. visionctl
  end

  local result = vim.system({ visionctl, "install", provider }, {
    cwd = plugin_root,
    text = true,
  }):wait()

  if result.code ~= 0 then
    local detail = vim.trim(result.stderr or "")
    if detail == "" then
      detail = vim.trim(result.stdout or "")
    end
    if detail == "" then
      detail = "installer exited with code " .. tostring(result.code)
    end
    return nil, detail
  end

  return true
end

local function register_commands()
  pcall(vim.api.nvim_del_user_command, "VisionInstall")

  vim.api.nvim_create_user_command("VisionInstall", function(opts)
    local ok, err = install_provider(opts.args)
    if ok then
      notify("Installed " .. opts.args .. " integration")
    else
      notify(err, vim.log.levels.ERROR)
    end
  end, {
    nargs = 1,
    complete = function(arg_lead)
      local matches = {}
      for _, provider in ipairs(providers) do
        if provider:sub(1, #arg_lead) == arg_lead then
          matches[#matches + 1] = provider
        end
      end
      return matches
    end,
    desc = "Install a vision.nvim provider integration",
  })
end

local function register_shutdown()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup(LIFECYCLE_GROUP, { clear = true }),
    callback = function()
      pcall(session.stop)
    end,
    desc = "Stop vision.nvim on exit",
  })
end

local function set_visual_activity(mode)
  if capture.is_visual_mode(mode) then
    pcall(session.mark_visual_activity, visual_activity_key(mode))
  else
    pcall(session.clear_visual_activity)
  end
end

local function mark_current_visual_activity()
  set_visual_activity(vim.api.nvim_get_mode().mode)
end

local function mark_mode_change()
  local event = vim.v.event
  set_visual_activity(type(event) == "table" and event.new_mode or vim.api.nvim_get_mode().mode)
end

local function register_activity()
  local group = vim.api.nvim_create_augroup(ACTIVITY_GROUP, { clear = true })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = mark_current_visual_activity,
    desc = "Track the most recent vision.nvim Visual mode activity",
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = mark_mode_change,
    desc = "Track the most recent vision.nvim Visual mode activity",
  })
end

function M.setup(opts)
  if session.is_running() then
    session.stop()
  end

  current_config = config.apply(opts)
  register_commands()
  register_shutdown()
  register_activity()

  local ok, err = session.start({
    consume_attachment = M.consume_attachment,
    visual_state = M.visual_state,
  })
  if not ok then
    notify(err, vim.log.levels.ERROR)
  end

  return M
end

function M.visual_state()
  local mode = vim.api.nvim_get_mode().mode
  local active = capture.is_visual_mode(mode)
  set_visual_activity(mode)

  local cwd = util.current_cwd()
  local runtime = session._runtime
  return {
    visual_active = active,
    last_visual_at = util.json_null(runtime.last_visual_at),
    cwd = util.json_null(cwd),
    roots = cwd and { cwd } or {},
    mode = mode,
  }
end

function M.consume_attachment()
  local envelope = capture.consume(current_config)
  if not envelope then
    return nil
  end

  pcall(session.mark_visual_activity, visual_activity_key(vim.api.nvim_get_mode().mode))

  if current_config.selection.clear_after_send then
    clear_visual_selection()
    pcall(session.clear_visual_activity)
  end

  return envelope
end

M.capture = capture.consume

return M
