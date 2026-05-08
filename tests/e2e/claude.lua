local h = require("tests.e2e.support")

local M = {
  name = "e2e.claude",
}

local real_home = vim.env.HOME or ""

local function write_claude_settings(settings_path, command_path)
  h.write_file(settings_path, vim.json.encode({
    hooks = {
      UserPromptSubmit = {
        {
          hooks = {
            {
              type = "command",
              command = command_path,
            },
          },
        },
      },
    },
  }))
end

local function claude_argv(opts)
  local argv = {
    "claude",
    "-p",
    "--setting-sources",
    "project,local",
    "--settings",
    opts.settings_path,
    "--tools=",
    "--output-format",
    opts.output_format or "json",
  }

  if opts.verbose then
    argv[#argv + 1] = "--verbose"
  end
  if opts.include_hook_events then
    argv[#argv + 1] = "--include-hook-events"
  end

  argv[#argv + 1] = opts.prompt
  return argv
end

local function run_claude(opts)
  return h.run_command(claude_argv(opts), {
    cwd = opts.cwd,
    env = {
      HOME = opts.home,
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

local function find_event(events, predicate)
  for _, event in ipairs(events) do
    if predicate(event) then
      return event
    end
  end
  return nil
end

local function assistant_text(event)
  if not event or not event.message or not event.message.content then
    return ""
  end

  local parts = {}
  for _, item in ipairs(event.message.content) do
    if type(item) == "table" and item.type == "text" and type(item.text) == "string" then
      parts[#parts + 1] = item.text
    end
  end
  return vim.trim(table.concat(parts, ""))
end

function M.run()
  h.truthy(vim.fn.exepath("claude") ~= "", "claude executable not found")
  h.truthy(type(real_home) == "string" and real_home ~= "", "HOME is not set for claude e2e")

  h.with_tempdir(function(tmp)
    local installer_home = vim.fs.joinpath(tmp, "installer-home")
    local claude_config_dir = vim.fs.joinpath(tmp, "claude-config")
    local data_home = vim.fs.joinpath(tmp, "data")
    local workspace_root = vim.fs.joinpath(tmp, "workspace")
    local nested_cwd = vim.fs.joinpath(workspace_root, "nested")
    local file_path = vim.fs.joinpath(workspace_root, "main.txt")
    local preflight_settings_path = vim.fs.joinpath(tmp, "preflight-settings.json")
    local settings_path = vim.fs.joinpath(claude_config_dir, "settings.json")
    local preflight_hook_path = vim.fs.joinpath(tmp, "preflight-hook.sh")
    local token = h.new_token("VISIONCLAUDEE2E")
    local prompt = table.concat({
      "Read the extra hook context attached to this prompt.",
      "If it includes a <visual-selection> block, reply with exactly the selected text from that block and nothing else.",
      "If there is no <visual-selection> block, reply with exactly MISSING.",
    }, " ")
    local child = nil

    local ok, err = xpcall(function()
      h.mkdir(installer_home)
      h.mkdir(claude_config_dir)
      h.mkdir(data_home)
      h.mkdir(workspace_root)
      h.mkdir(nested_cwd)

      h.assert_command_ok(h.run_command({ "git", "init", "-q" }, {
        cwd = workspace_root,
      }), "git init")

      h.write_file(preflight_hook_path, table.concat({
        "#!/bin/sh",
        "printf '%s' '{\"decision\":\"block\",\"reason\":\"VISION_BLOCKED\",\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\"}}'",
        "",
      }, "\n"))
      h.assert_command_ok(h.run_command({ "chmod", "+x", preflight_hook_path }), "chmod preflight hook")
      write_claude_settings(preflight_settings_path, preflight_hook_path)

      local preflight = run_claude({
        home = real_home,
        data_home = data_home,
        cwd = nested_cwd,
        prompt = "Say OK and nothing else.",
        settings_path = preflight_settings_path,
        output_format = "stream-json",
        verbose = true,
        include_hook_events = true,
      })
      h.assert_command_ok(preflight, "claude print preflight")
      local preflight_output = h.combined_output(preflight)
      h.truthy(
        preflight_output:find('"subtype":"hook_started"', 1, true) ~= nil
          and preflight_output:find('"hook_name":"UserPromptSubmit"', 1, true) ~= nil
          and preflight_output:find("VISION_BLOCKED", 1, true) ~= nil,
        "claude did not honor the temp UserPromptSubmit hook:\n" .. h.trimmed_tail(preflight_output)
      )

      h.assert_command_ok(h.run_command({ vim.fs.joinpath(h.root, "scripts", "visionctl"), "install", "claude" }, {
        env = {
          HOME = installer_home,
          CLAUDE_CONFIG_DIR = claude_config_dir,
        },
      }), "claude installer")

      child = h.start_child({
        cwd = workspace_root,
        workspace_root = workspace_root,
        env = {
          HOME = installer_home,
          VISION_NVIM_DATA_HOME = data_home,
        },
      })

      local envelope = h.seed_unsaved_visual_selection(child, file_path, token)
      h.eq(envelope.mode, "v")
      h.eq(envelope.envelope.attachment.mode, "char")
      h.eq(envelope.envelope.attachment.text, token)
      h.falsy(h.read_file(file_path):find(token, 1, true) ~= nil, "token leaked to disk before claude e2e")

      local result = run_claude({
        home = real_home,
        data_home = data_home,
        cwd = nested_cwd,
        prompt = prompt,
        settings_path = settings_path,
        output_format = "stream-json",
        verbose = true,
        include_hook_events = true,
        timeout_ms = 300000,
      })
      h.assert_command_ok(result, "claude print e2e")

      local events = decode_jsonl(result.stdout or "")
      local hook_response = find_event(events, function(event)
        return event.type == "system" and event.subtype == "hook_response" and event.hook_name == "UserPromptSubmit"
      end)
      local assistant_event = find_event(events, function(event)
        return event.type == "assistant"
      end)
      local result_event = find_event(events, function(event)
        return event.type == "result"
      end)

      h.truthy(hook_response ~= nil, "claude did not report a UserPromptSubmit hook response")
      h.eq(hook_response.outcome, "success")

      local submitted_context = ""
      if type(hook_response.output) == "string" and hook_response.output ~= "" then
        local hook_payload = vim.json.decode(hook_response.output)
        if hook_payload.hookSpecificOutput then
          submitted_context = hook_payload.hookSpecificOutput.additionalContext or ""
        end
      end
      h.truthy(
        submitted_context:find(token, 1, true) ~= nil,
        table.concat({
          "claude hook response did not include the visual selection token",
          "hook output:",
          tostring(hook_response.output),
          "submitted context:",
          submitted_context,
          "output tail:",
          h.trimmed_tail(h.combined_output(result)),
        }, "\n")
      )

      local final_message = assistant_text(assistant_event)
      if final_message == "" and result_event then
        final_message = vim.trim(result_event.result or "")
      end
      h.eq(final_message, token, table.concat({
        "unexpected final Claude message",
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
