<h1 align="center">vision.nvim</h1>

> share your neovim context with agents through visual mode

<div align="center">

![Neovim](https://img.shields.io/badge/NeoVim-%2357A143.svg?&style=for-the-badge&logo=neovim&logoColor=white)
[![GitHub stars](https://img.shields.io/github/stars/azorng/vision.nvim?style=for-the-badge)](https://github.com/azorng/vision.nvim/stargazers)
![Last Commit](https://img.shields.io/github/last-commit/azorng/vision.nvim?style=for-the-badge)

</div>

## About

vision.nvim lets Visual mode act as the bridge between your editor context and your agents.
When you prompt your agent from Visual mode, it automatically attaches the relevant Neovim context from the active editor state.

## How it works

```text
User prompt
-> agent integration runs visionctl hook <provider>
-> visionctl connects to the matching vision.nvim session
-> vision.nvim captures Visual-mode editor context
-> visionctl renders provider-specific context
-> agent receives it with the prompt
```

### Concepts

- **User prompt:** The message you submit to Codex, Claude, or OpenCode.
- **Agent integration:** The provider-specific hook/plugin installed by `:VisionInstall <provider>`. It runs when you submit a prompt.
- **vision.nvim session:** A registered live endpoint for a Neovim instance. It includes a local socket/TCP listener plus a JSON discovery record on disk.
- **visionctl:** The short-lived command-line bridge. It finds the matching vision.nvim session, asks that Neovim process for Visual-mode context, renders the result, and returns it to the agent.
- **vision.nvim:** The Lua plugin running inside Neovim. It owns editor state: Visual mode state, selection range, current file, cursor, line, diagnostics.

## Install

```lua
{
  "azorng/vision.nvim",
  config = function()
    require("vision").setup({})
  end,
}
```

Then install a provider integration from inside Neovim:

```vim
:VisionInstall codex
:VisionInstall claude
:VisionInstall opencode
```

`vision.nvim` installs provider integrations by editing the corresponding agent config:

- **Codex:** adds a prompt hook in `~/.codex/hooks.json`.
- **Claude:** adds a prompt hook in `~/.claude/settings.json`.
- **OpenCode:** writes a managed plugin to `$OPENCODE_CONFIG_DIR/plugins/vision-nvim.js`, or `~/.config/opencode/plugins/vision-nvim.js` by default.

After installing an integration, restart any already-running agent session so the agent reloads its config.

## Usage

Enter Visual mode in Neovim when submitting your prompt. The integration will
attach the context automatically.

If not in Visual mode, nothing will be sent to the agents.

## Configuration

```lua
-- Default configuration with all available options
require("vision").setup({
  selection = {
    clear_after_send = true,
  },
  context = {
    current_file = true,
    cursor = false,
    current_line = false,
    diagnostics = false,
  },
})
```
