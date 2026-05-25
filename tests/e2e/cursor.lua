local h = require("tests.e2e.support")

local M = {
  name = "e2e.cursor",
}

local real_home = vim.env.HOME or ""
local cli_config_source = vim.fs.joinpath(real_home, ".cursor", "cli-config.json")

local function cursor_argv(opts)
  return {
    "cursor-agent",
    "--print",
    "--output-format",
    "text",
    "--mode",
    "ask",
    "--trust",
    "--workspace",
    opts.cwd,
    opts.prompt,
  }
end

local function run_cursor(opts)
  return h.run_command(cursor_argv(opts), {
    cwd = opts.cwd,
    env = {
      CURSOR_CONFIG_DIR = opts.config_dir,
      CURSOR_DATA_DIR = opts.cursor_data_dir,
      HOME = real_home,
      NO_COLOR = "1",
      VISION_NVIM_DATA_HOME = opts.data_home,
    },
  }, opts.timeout_ms or 240000)
end

function M.run()
  h.truthy(vim.fn.exepath("cursor-agent") ~= "", "cursor-agent executable not found")
  h.truthy(type(real_home) == "string" and real_home ~= "", "HOME is not set for cursor e2e")
  h.truthy(vim.fn.filereadable(cli_config_source) == 1, "missing ~/.cursor/cli-config.json for cursor e2e")

  h.with_tempdir(function(tmp)
    local home = vim.fs.joinpath(tmp, "home")
    local cursor_dir = vim.fs.joinpath(home, ".cursor")
    local cursor_config_dir = vim.fs.joinpath(tmp, "cursor-config")
    local cursor_data_dir = vim.fs.joinpath(tmp, "cursor-data")
    local data_home = vim.fs.joinpath(tmp, "data")
    local workspace_root = vim.fs.joinpath(tmp, "workspace")
    local project_cursor_dir = vim.fs.joinpath(workspace_root, ".cursor")
    local nested_cwd = vim.fs.joinpath(workspace_root, "nested")
    local file_path = vim.fs.joinpath(workspace_root, "main.txt")
    local token = h.new_token("VISIONCURSORE2E")
    local prompt = table.concat({
      "Read the extra context attached to this prompt.",
      "If it includes a <visual-selection> block, reply with exactly the selected text from that block and nothing else.",
      "If there is no <visual-selection> block, reply with exactly MISSING.",
    }, " ")
    local child = nil

    local ok, err = xpcall(function()
      h.mkdir(cursor_dir)
      h.mkdir(cursor_config_dir)
      h.mkdir(cursor_data_dir)
      h.mkdir(data_home)
      h.mkdir(workspace_root)
      h.mkdir(project_cursor_dir)
      h.mkdir(nested_cwd)
      h.copy_file(cli_config_source, vim.fs.joinpath(cursor_config_dir, "cli-config.json"))

      h.assert_command_ok(h.run_command({ "git", "init", "-q" }, {
        cwd = workspace_root,
      }), "git init")

      h.assert_command_ok(h.run_command({ vim.fs.joinpath(h.root, "bin", "visionctl"), "install", "cursor" }, {
        env = {
          HOME = home,
        },
      }), "cursor installer")
      h.copy_file(vim.fs.joinpath(cursor_dir, "hooks.json"), vim.fs.joinpath(project_cursor_dir, "hooks.json"))

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
      h.falsy(h.read_file(file_path):find(token, 1, true) ~= nil, "token leaked to disk before cursor e2e")

      local direct_hook = h.run_command({ vim.fs.joinpath(h.root, "bin", "visionctl"), "hook", "cursor" }, {
        cwd = nested_cwd,
        env = {
          VISION_NVIM_DATA_HOME = data_home,
        },
        stdin = vim.json.encode({
          cwd = nested_cwd,
        }),
      })
      h.assert_command_ok(direct_hook, "direct cursor hook")
      h.truthy(
        (direct_hook.stdout or ""):find(token, 1, true) ~= nil,
        table.concat({
          "direct cursor hook did not include the visual selection token",
          "stdout:",
          direct_hook.stdout or "",
          "stderr:",
          direct_hook.stderr or "",
          "child mode:",
          child.exec([[ return vim.api.nvim_get_mode().mode ]]),
        }, "\n")
      )
      h.seed_unsaved_visual_selection(child, file_path, token)

      local result = run_cursor({
        config_dir = cursor_config_dir,
        cursor_data_dir = cursor_data_dir,
        data_home = data_home,
        cwd = nested_cwd,
        prompt = prompt,
        timeout_ms = 300000,
      })
      h.assert_command_ok(result, "cursor-agent print e2e")

      local final_message = vim.trim(result.stdout or "")
      h.eq(final_message, token, table.concat({
        "unexpected final Cursor message",
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
