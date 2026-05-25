import shlex
from pathlib import Path

from ..common import SCRIPT_PATH, VisionError, read_json, write_json
from .base import Provider, payload_cwd
from .command_hooks import entry_signature


CURSOR_HOOK_EVENT = "sessionStart"


def cursor_config_dir():
    return Path.home() / ".cursor"


def hook_command():
    return shlex.quote(str(SCRIPT_PATH)) + " hook cursor"


def hook_entry():
    return {
        "command": hook_command(),
    }


def entry_command(entry):
    if isinstance(entry, dict) and isinstance(entry.get("command"), str):
        return entry["command"]
    return None


def merge_cursor_hook_entry(target_file, state_file, new_entry):
    existing = read_json(target_file)
    state = read_json(state_file)

    version = existing.get("version")
    if version is None:
        existing["version"] = 1
    elif version != 1:
        raise VisionError(f'{target_file} has unsupported "version": {version}')

    hooks = existing.get("hooks")
    if hooks is None:
        hooks = {}
    if not isinstance(hooks, dict):
        raise VisionError(f'{target_file} has a non-object "hooks" value')
    hooks = dict(hooks)

    current = hooks.get(CURSOR_HOOK_EVENT)
    if current is None:
        current = []
    if not isinstance(current, list):
        raise VisionError(f"{target_file} has a non-array {CURSOR_HOOK_EVENT} hook list")

    managed = state.get("managed_hooks", {}).get(CURSOR_HOOK_EVENT, [])
    previous = {entry_signature(entry) for entry in managed if isinstance(entry, dict)}
    new_command = entry_command(new_entry)
    filtered = []
    for entry in current:
        if isinstance(entry, dict) and entry_signature(entry) in previous:
            continue
        if new_command and entry_command(entry) == new_command:
            continue
        filtered.append(entry)

    hooks[CURSOR_HOOK_EVENT] = [new_entry] + filtered
    existing["hooks"] = hooks

    write_json(target_file, existing)
    write_json(state_file, {
        "managed": True,
        "version": 1,
        "managed_hooks": {
            CURSOR_HOOK_EVENT: [new_entry],
        },
    })


class CursorProvider(Provider):
    def __init__(self):
        super().__init__("cursor")

    def accept_promptless_payload(self):
        return True

    def resolve_cwd(self, payload):
        return payload_cwd(payload) or super().resolve_cwd(payload)

    def wrap(self, context):
        return {
            "additional_context": context,
        }

    def install(self):
        root = cursor_config_dir()
        merge_cursor_hook_entry(root / "hooks.json", root / "vision.nvim-hooks.json", hook_entry())
