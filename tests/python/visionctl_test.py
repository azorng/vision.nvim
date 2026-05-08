import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "visionctl"


loader = importlib.machinery.SourceFileLoader("visionctl", str(SCRIPT))
spec = importlib.util.spec_from_loader("visionctl", loader)
visionctl = importlib.util.module_from_spec(spec)
loader.exec_module(visionctl)


class Env:
    def __init__(self, **values):
        self.values = values
        self.previous = {}

    def __enter__(self):
        for key, value in self.values.items():
            self.previous[key] = os.environ.get(key)
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def __exit__(self, *_):
        for key, value in self.previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


class VisionctlTest(unittest.TestCase):
    def test_render_context_formats_visual_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            file_path = root / "lua" / "main.lua"
            envelope = {
                "schema": 1,
                "workspace": {
                    "cwd": str(root),
                    "roots": [str(root)],
                },
                "attachment": {
                    "type": "visual_selection",
                    "file": str(file_path),
                    "mode": "line",
                    "range": {
                        "start_line": 1,
                        "start_col": 0,
                        "end_line": 2,
                        "end_col": 10,
                    },
                    "text": "local value = 1\nprint(value)",
                },
                "context": {
                    "current_file": str(file_path),
                    "diagnostics": [
                        {
                            "file": str(file_path),
                            "severity": "error",
                            "message": "broken",
                            "start_line": 0,
                            "start_col": 1,
                        }
                    ],
                },
            }

            rendered = visionctl.render_context(envelope, str(root))

            self.assertIn("Path: lua/main.lua", rendered)
            self.assertIn("```lua lua/main.lua (lines 2-3)", rendered)
            self.assertIn("local value = 1", rendered)
            self.assertIn("[ERROR] Line 1, Column 2: broken", rendered)

    def test_codex_install_is_idempotent_and_enables_hooks(self):
        with tempfile.TemporaryDirectory() as tmp:
            codex_home = Path(tmp) / ".codex"
            with Env(CODEX_HOME=str(codex_home)):
                visionctl.PROVIDERS["codex"].install()
                visionctl.PROVIDERS["codex"].install()

            hooks = json.loads((codex_home / "hooks.json").read_text(encoding="utf-8"))
            entries = hooks["hooks"]["UserPromptSubmit"]
            self.assertEqual(len(entries), 1)
            command = entries[0]["hooks"][0]["command"]
            self.assertIn(" hook codex", command)

            config = (codex_home / "config.toml").read_text(encoding="utf-8")
            self.assertIn("suppress_unstable_features_warning = true", config)
            self.assertIn("[features]", config)
            self.assertIn("hooks = true", config)

    def test_select_session_prefers_longest_matching_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            data = tmp_path / "data"
            sessions = data / "sessions"
            sessions.mkdir(parents=True)
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            parent = tmp_path / "repo"
            nested = parent / "nested"
            nested.mkdir(parents=True)

            records = [
                {
                    "schema": 1,
                    "id": "parent",
                    "pid": os.getpid(),
                    "cwd": str(parent),
                    "roots": [str(parent)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 1},
                    "token": "x",
                    "started_at": now,
                },
                {
                    "schema": 1,
                    "id": "nested",
                    "pid": os.getpid(),
                    "cwd": str(nested),
                    "roots": [str(nested)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 2},
                    "token": "x",
                    "started_at": now,
                },
            ]
            for record in records:
                (sessions / (record["id"] + ".json")).write_text(json.dumps(record), encoding="utf-8")

            with Env(VISION_NVIM_DATA_HOME=str(data)):
                selected = visionctl.select_session(str(nested))

            self.assertEqual(selected["id"], "nested")


if __name__ == "__main__":
    unittest.main()
