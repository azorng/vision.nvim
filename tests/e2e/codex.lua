local h = require("tests.e2e.support")

local M = {
  name = "e2e.codex",
}

local auth_source = vim.fs.joinpath(vim.env.HOME or "", ".codex", "auth.json")

local function codex_trust_hash(command)
  local identity = '{"event_name":"user_prompt_submit","hooks":[{"async":false,"command":'
    .. vim.json.encode(command)
    .. ',"timeout":600,"type":"command"}]}'
  return "sha256:" .. vim.fn.sha256(identity)
end

local function write_codex_config(config_path, paths, hooks_path, command_path)
  local lines = {
    "suppress_unstable_features_warning = true",
    "",
    "[features]",
    "hooks = true",
    "",
  }

  for _, path in ipairs(paths) do
    local real_path = (vim.uv or vim.loop).fs_realpath(path) or vim.fs.normalize(path)
    lines[#lines + 1] = ("[projects.%s]"):format(vim.json.encode(real_path))
    lines[#lines + 1] = 'trust_level = "trusted"'
    lines[#lines + 1] = ""
  end

  if hooks_path and command_path then
    local real_hooks_path = (vim.uv or vim.loop).fs_realpath(hooks_path) or vim.fs.normalize(hooks_path)
    local state_key = ("%s:user_prompt_submit:0:0"):format(real_hooks_path)
    lines[#lines + 1] = ("[hooks.state.%s]"):format(vim.json.encode(state_key))
    lines[#lines + 1] = "enabled = true"
    lines[#lines + 1] = ("trusted_hash = %s"):format(vim.json.encode(codex_trust_hash(command_path)))
    lines[#lines + 1] = ""
  end

  h.write_file(config_path, table.concat(lines, "\n"))
end

local function write_codex_hooks(hooks_path, command_path)
  h.write_file(hooks_path, vim.json.encode({
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

local function codex_argv(opts)
  local argv = {
    "codex",
    "exec",
    "--color",
    "never",
    "-s",
    "read-only",
    "-c",
    "default_tools_enabled=false",
    "-C",
    opts.cwd,
  }

  if opts.last_message_path then
    vim.list_extend(argv, {
      "--output-last-message",
      opts.last_message_path,
    })
  end

  argv[#argv + 1] = opts.prompt
  return argv
end

local function run_codex(opts)
  return h.run_command(codex_argv(opts), {
    cwd = opts.cwd,
    env = {
      HOME = opts.home,
      CODEX_HOME = opts.codex_home,
      VISION_NVIM_DATA_HOME = opts.data_home,
    },
  }, opts.timeout_ms or 240000)
end

function M.run()
  h.truthy(vim.fn.exepath("codex") ~= "", "codex executable not found")
  h.truthy(vim.fn.filereadable(auth_source) == 1, "missing ~/.codex/auth.json for codex e2e")

  h.with_tempdir(function(tmp)
    local home = vim.fs.joinpath(tmp, "home")
    local codex_home = vim.fs.joinpath(home, ".codex")
    local data_home = vim.fs.joinpath(tmp, "data")
    local workspace_root = vim.fs.joinpath(tmp, "workspace")
    local nested_cwd = vim.fs.joinpath(workspace_root, "nested")
    local file_path = vim.fs.joinpath(workspace_root, "main.txt")
    local config_path = vim.fs.joinpath(codex_home, "config.toml")
    local hooks_path = vim.fs.joinpath(codex_home, "hooks.json")
    local preflight_hook_path = vim.fs.joinpath(tmp, "preflight-hook.sh")
    local last_message_path = vim.fs.joinpath(tmp, "codex-last-message.txt")
    local token = h.new_token("VISIONCODEXE2E")
    local prompt = table.concat({
      "Read the extra hook context attached to this prompt.",
      "If it includes a <visual-selection> block, reply with exactly the selected text from that block and nothing else.",
      "If there is no <visual-selection> block, reply with exactly MISSING.",
    }, " ")
    local child = nil

    local ok, err = xpcall(function()
      h.mkdir(home)
      h.mkdir(codex_home)
      h.mkdir(data_home)
      h.mkdir(workspace_root)
      h.mkdir(nested_cwd)
      h.copy_file(auth_source, vim.fs.joinpath(codex_home, "auth.json"))

      h.assert_command_ok(h.run_command({ "git", "init", "-q" }, {
        cwd = workspace_root,
      }), "git init")

      h.write_file(preflight_hook_path, table.concat({
        "#!/bin/sh",
        "printf '%s' '{\"decision\":\"block\",\"reason\":\"VISION_BLOCKED\",\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\"}}'",
        "",
      }, "\n"))
      h.assert_command_ok(h.run_command({ "chmod", "+x", preflight_hook_path }), "chmod preflight hook")
      write_codex_hooks(hooks_path, preflight_hook_path)
      write_codex_config(config_path, { workspace_root, nested_cwd }, hooks_path, preflight_hook_path)

      local preflight = run_codex({
        home = home,
        codex_home = codex_home,
        data_home = data_home,
        cwd = nested_cwd,
        prompt = "Say OK and nothing else.",
      })
      h.assert_command_ok(preflight, "codex exec preflight")
      local preflight_output = h.combined_output(preflight)
      h.truthy(
        preflight_output:find("hook: UserPromptSubmit", 1, true) ~= nil
          and preflight_output:find("hook: UserPromptSubmit Blocked", 1, true) ~= nil,
        "codex exec did not honor the temp UserPromptSubmit hook:\n" .. h.trimmed_tail(preflight_output)
      )

      h.assert_command_ok(h.run_command({ vim.fs.joinpath(h.root, "scripts", "visionctl"), "install", "codex" }, {
        env = {
          HOME = home,
          CODEX_HOME = codex_home,
        },
      }), "codex installer")

      child = h.start_child({
        cwd = workspace_root,
        workspace_root = workspace_root,
        env = {
          HOME = home,
          CODEX_HOME = codex_home,
          VISION_NVIM_DATA_HOME = data_home,
        },
      })

      local envelope = h.seed_unsaved_visual_selection(child, file_path, token)
      h.eq(envelope.mode, "v")
      h.eq(envelope.envelope.attachment.mode, "char")
      h.eq(envelope.envelope.attachment.text, token)
      h.falsy(h.read_file(file_path):find(token, 1, true) ~= nil, "token leaked to disk before codex e2e")

      local direct_hook = h.run_command({ vim.fs.joinpath(h.root, "scripts", "visionctl"), "hook", "codex" }, {
        cwd = nested_cwd,
        env = {
          VISION_NVIM_DATA_HOME = data_home,
        },
        stdin = vim.json.encode({
          turn_id = "direct",
          prompt = "direct hook check",
        }),
      })
      h.assert_command_ok(direct_hook, "direct codex hook")
      h.truthy(
        (direct_hook.stdout or ""):find(token, 1, true) ~= nil,
        table.concat({
          "direct codex hook did not include the visual selection token",
          "stdout:",
          direct_hook.stdout or "",
          "stderr:",
          direct_hook.stderr or "",
          "sessions:",
          h.run_command({ "sh", "-c", "find \"$VISION_NVIM_DATA_HOME\" -type f -maxdepth 3 -print -exec cat {} \\;" }, {
            env = {
              VISION_NVIM_DATA_HOME = data_home,
            },
          }).stdout or "",
          "child mode:",
          child.exec([[ return vim.api.nvim_get_mode().mode ]]),
        }, "\n")
      )
      h.seed_unsaved_visual_selection(child, file_path, token)

      local result = run_codex({
        home = home,
        codex_home = codex_home,
        data_home = data_home,
        cwd = nested_cwd,
        prompt = prompt,
        last_message_path = last_message_path,
        timeout_ms = 300000,
      })
      h.assert_command_ok(result, "codex exec e2e")

      local output = h.combined_output(result)
      h.truthy(
        output:find("hook: UserPromptSubmit", 1, true) ~= nil,
        "codex exec did not report the UserPromptSubmit hook:\n" .. h.trimmed_tail(output)
      )

      local last_message = ""
      if vim.fn.filereadable(last_message_path) == 1 then
        last_message = vim.trim(h.read_file(last_message_path))
      end
      h.eq(last_message, token, table.concat({
        "unexpected final Codex message",
        "expected: " .. token,
        "actual:   " .. last_message,
        "output tail:",
        h.trimmed_tail(output),
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
