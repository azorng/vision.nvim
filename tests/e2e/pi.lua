local h = require("tests.e2e.support")

local M = {
  name = "e2e.pi",
}

local real_home = vim.env.HOME or ""
local source_agent_dir = vim.env.VISION_NVIM_E2E_PI_AGENT_DIR
  or vim.env.PI_CODING_AGENT_DIR
  or vim.fs.joinpath(real_home, ".pi", "agent")
local auth_source = vim.fs.joinpath(source_agent_dir, "auth.json")
local models_source = vim.fs.joinpath(source_agent_dir, "models.json")
local settings_source = vim.fs.joinpath(source_agent_dir, "settings.json")

local function pi_argv(opts)
  local argv = {
    "pi",
    "--mode",
    "json",
    "--no-session",
    "--no-tools",
    "--no-context-files",
    "--no-skills",
    "--no-prompt-templates",
    "--no-themes",
    "--offline",
  }

  if opts.provider and opts.provider ~= "" then
    vim.list_extend(argv, { "--provider", opts.provider })
  end
  if opts.model and opts.model ~= "" then
    vim.list_extend(argv, { "--model", opts.model })
  end

  argv[#argv + 1] = opts.prompt
  return argv
end

local function run_pi(opts)
  return h.run_command(pi_argv(opts), {
    cwd = opts.cwd,
    env = {
      HOME = real_home,
      PI_CODING_AGENT_DIR = opts.agent_dir,
      PI_CODING_AGENT_SESSION_DIR = opts.session_dir,
      PI_OFFLINE = "1",
      PI_SKIP_VERSION_CHECK = "1",
      PI_TELEMETRY = "0",
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

local function message_text(message)
  if type(message) ~= "table" then
    return ""
  end

  if type(message.content) == "string" then
    return vim.trim(message.content)
  end

  local parts = {}
  for _, item in ipairs(message.content or {}) do
    if type(item) == "table" and item.type == "text" and type(item.text) == "string" then
      parts[#parts + 1] = item.text
    end
  end
  return vim.trim(table.concat(parts, ""))
end

local function find_custom_context(events)
  for _, event in ipairs(events) do
    if
      event.type == "message_end"
      and type(event.message) == "table"
      and event.message.role == "custom"
      and event.message.customType == "vision.nvim"
    then
      return message_text(event.message)
    end

    if event.type == "agent_end" and type(event.messages) == "table" then
      for _, message in ipairs(event.messages) do
        if
          type(message) == "table"
          and message.role == "custom"
          and message.customType == "vision.nvim"
        then
          return message_text(message)
        end
      end
    end
  end
  return ""
end

local function assistant_text(events)
  local text = ""
  for _, event in ipairs(events) do
    if event.type == "message_end" and type(event.message) == "table" and event.message.role == "assistant" then
      text = message_text(event.message)
    end

    if event.type == "agent_end" and type(event.messages) == "table" then
      for _, message in ipairs(event.messages) do
        if type(message) == "table" and message.role == "assistant" then
          text = message_text(message)
        end
      end
    end
  end
  return text
end

local function write_filtered_settings(settings_path)
  local settings = {
    quietStartup = true,
    hideThinkingBlock = true,
    enableInstallTelemetry = false,
  }

  if vim.fn.filereadable(settings_source) == 1 then
    local ok, existing = pcall(vim.json.decode, h.read_file(settings_source))
    h.truthy(ok and type(existing) == "table", "invalid Pi settings JSON: " .. settings_source)

    for _, key in ipairs({
      "defaultProvider",
      "defaultModel",
      "defaultThinkingLevel",
      "enabledModels",
      "thinkingBudgets",
    }) do
      if existing[key] ~= nil then
        settings[key] = existing[key]
      end
    end
  end

  h.write_file(settings_path, vim.json.encode(settings))
end

function M.run()
  h.truthy(vim.fn.exepath("pi") ~= "", "pi executable not found")
  h.truthy(type(real_home) == "string" and real_home ~= "", "HOME is not set for pi e2e")

  h.with_tempdir(function(tmp)
    local agent_dir = vim.fs.joinpath(tmp, "pi-agent")
    local session_dir = vim.fs.joinpath(tmp, "pi-sessions")
    local data_home = vim.fs.joinpath(tmp, "data")
    local workspace_root = vim.fs.joinpath(tmp, "workspace")
    local nested_cwd = vim.fs.joinpath(workspace_root, "nested")
    local file_path = vim.fs.joinpath(workspace_root, "main.txt")
    local token = h.new_token("VISIONPIE2E")
    local prompt = table.concat({
      "Read the extra context attached to this prompt.",
      "If it includes a <visual-selection> block, reply with exactly the selected text from that block and nothing else.",
      "If there is no <visual-selection> block, reply with exactly MISSING.",
    }, " ")
    local child = nil

    local ok, err = xpcall(function()
      h.mkdir(agent_dir)
      h.mkdir(session_dir)
      h.mkdir(data_home)
      h.mkdir(workspace_root)
      h.mkdir(nested_cwd)

      if vim.fn.filereadable(auth_source) == 1 then
        h.copy_file(auth_source, vim.fs.joinpath(agent_dir, "auth.json"))
      end
      if vim.fn.filereadable(models_source) == 1 then
        h.copy_file(models_source, vim.fs.joinpath(agent_dir, "models.json"))
      end
      write_filtered_settings(vim.fs.joinpath(agent_dir, "settings.json"))

      h.assert_command_ok(h.run_command({ "git", "init", "-q" }, {
        cwd = workspace_root,
      }), "git init")

      h.assert_command_ok(h.run_command({ vim.fs.joinpath(h.root, "bin", "visionctl"), "install", "pi" }, {
        env = {
          PI_CODING_AGENT_DIR = agent_dir,
        },
      }), "pi installer")

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
      h.falsy(h.read_file(file_path):find(token, 1, true) ~= nil, "token leaked to disk before pi e2e")

      local direct_hook = h.run_command({ vim.fs.joinpath(h.root, "bin", "visionctl"), "hook", "pi" }, {
        cwd = nested_cwd,
        env = {
          VISION_NVIM_DATA_HOME = data_home,
        },
        stdin = vim.json.encode({
          prompt = "direct hook check",
          cwd = nested_cwd,
        }),
      })
      h.assert_command_ok(direct_hook, "direct pi hook")
      h.truthy(
        (direct_hook.stdout or ""):find(token, 1, true) ~= nil,
        table.concat({
          "direct pi hook did not include the visual selection token",
          "stdout:",
          direct_hook.stdout or "",
          "stderr:",
          direct_hook.stderr or "",
          "child mode:",
          child.exec([[ return vim.api.nvim_get_mode().mode ]]),
        }, "\n")
      )
      h.seed_unsaved_visual_selection(child, file_path, token)

      local result = run_pi({
        agent_dir = agent_dir,
        session_dir = session_dir,
        data_home = data_home,
        cwd = nested_cwd,
        provider = vim.env.VISION_NVIM_E2E_PI_PROVIDER,
        model = vim.env.VISION_NVIM_E2E_PI_MODEL,
        prompt = prompt,
        timeout_ms = 300000,
      })
      h.assert_command_ok(result, "pi print e2e")

      local events = decode_jsonl(result.stdout or "")
      local submitted_context = find_custom_context(events)
      h.truthy(
        submitted_context:find(token, 1, true) ~= nil,
        table.concat({
          "Pi extension custom context did not include the visual selection token",
          "submitted context:",
          submitted_context,
          "output tail:",
          h.trimmed_tail(h.combined_output(result)),
        }, "\n")
      )

      local final_message = assistant_text(events)
      h.eq(final_message, token, table.concat({
        "unexpected final Pi message",
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
