local capture = require("vision.capture")
local config = require("vision.config")
local session = require("vision.session")

local M = {}

local ESC = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
local LIFECYCLE_GROUP = "vision.nvim.lifecycle"

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

function M.setup(opts)
  if session.is_running() then
    session.stop()
  end

  current_config = config.apply(opts)
  register_commands()
  register_shutdown()

  local ok, err = session.start({
    consume_attachment = M.consume_attachment,
  })
  if not ok then
    notify(err, vim.log.levels.ERROR)
  end

  return M
end

function M.consume_attachment()
  local envelope = capture.consume(current_config)
  if not envelope then
    return nil
  end

  if current_config.selection.clear_after_send then
    clear_visual_selection()
  end

  return envelope
end

M.capture = capture.consume

return M
