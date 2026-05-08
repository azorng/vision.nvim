# vision.nvim

use neovim visual mode as a bridge between editor context and your agent.

---

This plugin provides a bridge between neovim and your agent, creating a small
local service inside neovim. When you submit a prompt, the agent integration
asks that session for the active visual selection. If one exists, Vision injects
the context as additional prompt context.

## Install

```lua
{
  "azorng/vision.nvim",
  config = function()
    require("vision").setup()
  end,
}
```

## Usage

Install a provider integration from inside Neovim:

```vim
:VisionInstall codex
:VisionInstall claude
:VisionInstall opencode
```

External provider e2e tests use real CLIs and may be billable:

```sh
./scripts/test e2e
./scripts/test e2e codex
./scripts/test e2e claude
./scripts/test e2e opencode
```

Keep a visual selection active when submitting your prompt. The integration will
attach the context automatically.

After installing an integration, restart any already-running agent session so
the agent reloads its config.

## Configuration

```lua
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

## Commands

```vim
:VisionInstall codex
:VisionInstall claude
:VisionInstall opencode
```
