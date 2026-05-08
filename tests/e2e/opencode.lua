local h = require("tests.e2e.support")

local M = {
  name = "e2e.opencode",
}

local real_home = vim.env.HOME or ""

local function opencode_argv(opts)
  return {
    "opencode",
    "run",
    "--format",
    "json",
    "--dir",
    opts.cwd,
    opts.prompt,
  }
end

local function run_opencode(opts)
  return h.run_command(opencode_argv(opts), {
    cwd = opts.cwd,
    env = {
      HOME = real_home,
      OPENCODE_CONFIG = "",
      OPENCODE_CONFIG_CONTENT = "",
      OPENCODE_CONFIG_DIR = opts.config_dir,
      OPENCODE_DISABLE_AUTOUPDATE = "1",
      OPENCODE_DISABLE_PROJECT_CONFIG = "1",
      OPENCODE_PERMISSION = "",
      VISION_NVIM_DATA_HOME = opts.data_home,
    },
  }, opts.timeout_ms or 240000)
end

local function decode_jsonl(text)
  local events = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    if vim.trim(line) ~= "" then
      events[#events + 1] = vim.json.decode(line)
    end
  end
  return events
end

local function assistant_text(events)
  local text = ""
  for _, event in ipairs(events) do
    if event.type == "text" and type(event.part) == "table" and type(event.part.text) == "string" then
      text = event.part.text
    end
  end
  return vim.trim(text)
end

function M.run()
  h.truthy(vim.fn.exepath("opencode") ~= "", "opencode executable not found")
  h.truthy(type(real_home) == "string" and real_home ~= "", "HOME is not set for opencode e2e")

  h.with_tempdir(function(tmp)
    local config_dir = vim.fs.joinpath(tmp, "opencode-config")
    local data_home = vim.fs.joinpath(tmp, "data")
    local workspace_root = vim.fs.joinpath(tmp, "workspace")
    local nested_cwd = vim.fs.joinpath(workspace_root, "nested")
    local file_path = vim.fs.joinpath(workspace_root, "main.txt")
    local token = h.new_token("VISIONOPENCODEE2E")
    local prompt = table.concat({
      "Read the extra context attached to this prompt.",
      "If it includes a <visual-selection> block, reply with exactly the selected text from that block and nothing else.",
      "If there is no <visual-selection> block, reply with exactly MISSING.",
    }, " ")
    local child = nil

    local ok, err = xpcall(function()
      h.mkdir(config_dir)
      h.mkdir(data_home)
      h.mkdir(workspace_root)
      h.mkdir(nested_cwd)

      h.assert_command_ok(h.run_command({ "git", "init", "-q" }, {
        cwd = workspace_root,
      }), "git init")

      h.assert_command_ok(h.run_command({ vim.fs.joinpath(h.root, "bin", "visionctl"), "install", "opencode" }, {
        env = {
          OPENCODE_CONFIG_DIR = config_dir,
        },
      }), "opencode installer")

      child = h.start_child({
        cwd = workspace_root,
        workspace_root = workspace_root,
        env = {
          HOME = real_home,
          VISION_NVIM_DATA_HOME = data_home,
        },
      })

      local envelope = h.seed_unsaved_visual_selection(child, file_path, token)
      h.eq(envelope.mode, "v")
      h.eq(envelope.envelope.attachment.mode, "char")
      h.eq(envelope.envelope.attachment.text, token)
      h.falsy(h.read_file(file_path):find(token, 1, true) ~= nil, "token leaked to disk before opencode e2e")

      local direct_hook = h.run_command({ vim.fs.joinpath(h.root, "bin", "visionctl"), "hook", "opencode" }, {
        cwd = nested_cwd,
        env = {
          VISION_NVIM_DATA_HOME = data_home,
        },
        stdin = vim.json.encode({
          prompt = "direct hook check",
          cwd = nested_cwd,
        }),
      })
      h.assert_command_ok(direct_hook, "direct opencode hook")
      h.truthy(
        (direct_hook.stdout or ""):find(token, 1, true) ~= nil,
        table.concat({
          "direct opencode hook did not include the visual selection token",
          "stdout:",
          direct_hook.stdout or "",
          "stderr:",
          direct_hook.stderr or "",
          "child mode:",
          child.exec([[ return vim.api.nvim_get_mode().mode ]]),
        }, "\n")
      )
      h.seed_unsaved_visual_selection(child, file_path, token)

      local result = run_opencode({
        config_dir = config_dir,
        data_home = data_home,
        cwd = nested_cwd,
        prompt = prompt,
        timeout_ms = 300000,
      })
      h.assert_command_ok(result, "opencode run e2e")

      local final_message = assistant_text(decode_jsonl(result.stdout or ""))
      h.eq(final_message, token, table.concat({
        "unexpected final OpenCode message",
        "expected: " .. token,
        "actual:   " .. final_message,
        "output tail:",
        h.trimmed_tail(h.combined_output(result)),
      }, "\n"))

      child.wait_for([[ return vim.api.nvim_get_mode().mode == "n" ]], 10000, 50)
    end, debug.traceback)

    if child then
      child.stop()
    end
    if not ok then
      error(err)
    end
  end)
end

return M
