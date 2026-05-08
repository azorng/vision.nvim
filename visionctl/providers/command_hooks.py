import json
import shlex

from ..common import SCRIPT_PATH, VisionError, read_json, write_json
from .base import Provider


class CommandHookProvider(Provider):
    def hook_command(self):
        return shlex.quote(str(SCRIPT_PATH)) + " hook " + self.name

    def hook_entry(self, command):
        hook = {
            "type": "command",
            "command": command,
        }
        return {
            "hooks": [hook],
        }

    def wrap(self, context):
        return {
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": context,
            },
        }


def entry_signature(entry):
    return json.dumps(entry, sort_keys=True, separators=(",", ":"))


def command_paths(entry):
    if not isinstance(entry, dict):
        return []
    hooks = entry.get("hooks")
    if not isinstance(hooks, list):
        return []
    commands = []
    for hook in hooks:
        if isinstance(hook, dict) and hook.get("type") == "command" and isinstance(hook.get("command"), str):
            commands.append(hook["command"])
    return commands


def merge_hook_entry(target_file, state_file, new_entry):
    existing = read_json(target_file)
    state = read_json(state_file)

    hooks = existing.get("hooks")
    if hooks is None:
        hooks = {}
    if not isinstance(hooks, dict):
        raise VisionError(f'{target_file} has a non-object "hooks" value')
    hooks = dict(hooks)

    current = hooks.get("UserPromptSubmit")
    if current is None:
        current = []
    if not isinstance(current, list):
        raise VisionError(f'{target_file} has a non-array UserPromptSubmit hook list')

    managed = state.get("managed_hooks", {}).get("UserPromptSubmit", [])
    previous = {entry_signature(entry) for entry in managed if isinstance(entry, dict)}
    new_commands = set(command_paths(new_entry))
    filtered = []
    for entry in current:
        if isinstance(entry, dict) and entry_signature(entry) in previous:
            continue
        if any(command in new_commands for command in command_paths(entry)):
            continue
        filtered.append(entry)

    hooks["UserPromptSubmit"] = [new_entry] + filtered
    existing["hooks"] = hooks

    write_json(target_file, existing)
    write_json(state_file, {
        "managed": True,
        "version": 1,
        "managed_hooks": {
            "UserPromptSubmit": [new_entry],
        },
    })
