import hashlib
import json
import os
import re
from pathlib import Path

from ..common import read_text, write_text
from .command_hooks import CommandHookProvider, merge_hook_entry


TABLE_HEADER_RE = re.compile(r"^\s*\[.+\]\s*(?:#.*)?$")
FEATURES_HEADER_RE = re.compile(r"""^\s*\[\s*(?:features|"features"|'features')\s*\]\s*(?:#.*)?$""")


def is_table_header(line):
    return TABLE_HEADER_RE.match(line) is not None


def is_features_header(line):
    return FEATURES_HEADER_RE.match(line) is not None


def codex_trust_state(hooks_path, entry):
    command = entry["hooks"][0]["command"]
    identity = {
        "event_name": "user_prompt_submit",
        "hooks": [
            {
                "type": "command",
                "command": command,
                "timeout": 600,
                "async": False,
            }
        ],
    }
    serialized = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    key = f"{Path(hooks_path).resolve(strict=False)}:user_prompt_submit:0:0"
    return key, "sha256:" + hashlib.sha256(serialized).hexdigest()


def ensure_codex_config(path, hooks_path, entry):
    text = read_text(path).replace("\r\n", "\n")
    warning_line = "suppress_unstable_features_warning = true"
    warning_re = re.compile(r"(?m)^suppress_unstable_features_warning\s*=\s*(true|false)(?:\s*#.*)?$")
    if warning_re.search(text):
        text = warning_re.sub(warning_line, text, count=1)
    else:
        text = warning_line + ("\n\n" + text if text else "\n")

    source_lines = text.splitlines()
    features_at = next((i for i, line in enumerate(source_lines) if is_features_header(line)), None)
    if features_at is None:
        source_lines.extend(["", "[features]", "hooks = true"])
    else:
        end = features_at + 1
        while end < len(source_lines):
            if is_table_header(source_lines[end]):
                break
            end += 1

        hooks_at = None
        for index in range(features_at + 1, end):
            if re.match(r"^hooks\s*=", source_lines[index].strip()):
                hooks_at = index
                break
        if hooks_at is None:
            source_lines.insert(end, "hooks = true")
        else:
            source_lines[hooks_at] = "hooks = true"
    text = "\n".join(source_lines)

    lines = []
    trust_key, trusted_hash = codex_trust_state(hooks_path, entry)
    trust_header = f"[hooks.state.{json.dumps(trust_key)}]"
    state_header_re = re.compile(r"^\[hooks\.state\.")
    skip_state_block = False
    previous_blank = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == trust_header:
            skip_state_block = True
            continue
        if skip_state_block:
            if is_table_header(stripped):
                skip_state_block = False
            else:
                continue
        if state_header_re.match(stripped):
            skip_state_block = stripped == trust_header
            if skip_state_block:
                continue

        if stripped == "":
            if not previous_blank:
                lines.append("")
            previous_blank = True
            continue
        if is_table_header(stripped) and lines and lines[-1] != "":
            lines.append("")
        lines.append(line.rstrip())
        previous_blank = False
    while lines and lines[-1] == "":
        lines.pop()
    if lines:
        lines.append("")
    lines.extend([
        trust_header,
        "enabled = true",
        "trusted_hash = " + json.dumps(trusted_hash),
    ])
    write_text(path, "\n".join(lines) + "\n")


class CodexProvider(CommandHookProvider):
    def __init__(self):
        super().__init__("codex")

    def install(self):
        root = Path(os.environ.get("CODEX_HOME") or (Path.home() / ".codex"))
        hooks_path = root / "hooks.json"
        entry = self.hook_entry(self.hook_command())
        merge_hook_entry(hooks_path, root / "vision.nvim-hooks.json", entry)
        ensure_codex_config(root / "config.toml", hooks_path, entry)
