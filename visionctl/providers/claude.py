import os
from pathlib import Path

from .base import payload_cwd
from .command_hooks import CommandHookProvider, merge_hook_entry


class ClaudeProvider(CommandHookProvider):
    def __init__(self):
        super().__init__("claude")

    def resolve_cwd(self, payload):
        return payload_cwd(payload) or super().resolve_cwd(payload)

    def install(self):
        root = Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude"))
        entry = self.hook_entry(self.hook_command())
        merge_hook_entry(root / "settings.json", root / "vision.nvim-hooks.json", entry)
