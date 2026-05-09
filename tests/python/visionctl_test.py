import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "bin" / "visionctl"

sys.path.insert(0, str(ROOT))
import visionctl


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
            expected = "\n".join([
                "<additional-data>",
                "  Below is context that may help with the user query. Ignore if not relevant",
                "",
                "  <current-file>",
                "    Path: lua/main.lua",
                "  </current-file>",
                "",
                "  <attached-files>",
                "    <visual-selection>",
                "      ```lua lua/main.lua (lines 2-3)",
                "      local value = 1",
                "      print(value)",
                "      ```",
                "    </visual-selection>",
                "",
                "    <linter-errors>",
                "      [ERROR] Line 1, Column 2: broken",
                "    </linter-errors>",
                "  </attached-files>",
                "</additional-data>",
            ])

            self.assertEqual(rendered, expected)
            self.assertIn("Path: lua/main.lua", rendered)
            self.assertIn("```lua lua/main.lua (lines 2-3)", rendered)
            self.assertIn("local value = 1", rendered)
            self.assertIn("[ERROR] Line 1, Column 2: broken", rendered)

    def test_render_context_omits_unselected_visual_range(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            file_path = root / "main.py"
            envelope = {
                "schema": 1,
                "workspace": {
                    "cwd": str(root),
                    "roots": [str(root)],
                },
                "attachment": {
                    "type": "visual_selection",
                    "file": str(file_path),
                    "mode": "char",
                    "selected": False,
                    "range": {
                        "start_line": 0,
                        "start_col": 0,
                        "end_line": 0,
                        "end_col": 0,
                    },
                    "text": "",
                },
                "context": {
                    "current_file": str(file_path),
                    "cursor": {
                        "line": 0,
                        "col": 0,
                    },
                },
            }

            rendered = visionctl.render_context(envelope, str(root))

            self.assertIn("<current-file>", rendered)
            self.assertIn("<cursor-data>", rendered)
            self.assertNotIn("<visual-selection>", rendered)
            self.assertNotIn("<attached-files>", rendered)

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

    def test_codex_install_updates_commented_features_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            codex_home = Path(tmp) / ".codex"
            codex_home.mkdir()
            (codex_home / "config.toml").write_text(
                "\n".join([
                    "suppress_unstable_features_warning = false # old",
                    "",
                    "[features] # user comment",
                    "foo = true",
                    "",
                    "[projects.\"/tmp/repo\"] # user comment",
                    'trust_level = "trusted"',
                    "",
                ]),
                encoding="utf-8",
            )

            with Env(CODEX_HOME=str(codex_home)):
                visionctl.PROVIDERS["codex"].install()

            config = (codex_home / "config.toml").read_text(encoding="utf-8")
            self.assertEqual(config.count("suppress_unstable_features_warning"), 1)
            self.assertEqual(config.count("[features]"), 1)
            self.assertIn("[features] # user comment", config)
            self.assertIn("hooks = true", config)
            if tomllib:
                tomllib.loads(config)

    def test_opencode_install_writes_managed_plugin(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_dir = Path(tmp) / "opencode-config"
            with Env(OPENCODE_CONFIG_DIR=str(config_dir), XDG_CONFIG_HOME=None):
                visionctl.PROVIDERS["opencode"].install()
                visionctl.PROVIDERS["opencode"].install()

            plugin = config_dir / "plugins" / "vision-nvim.js"
            source = plugin.read_text(encoding="utf-8")

            self.assertIn("Managed by vision.nvim", source)
            self.assertIn(str(SCRIPT), source)
            self.assertIn('"chat.message"', source)
            self.assertIn('"hook", "opencode"', source)
            self.assertIn("Array.isArray(output?.parts)", source)
            self.assertIn("try {", source)

    def test_opencode_wrap_returns_plugin_payload(self):
        self.assertEqual(visionctl.PROVIDERS["opencode"].wrap("ctx"), {"context": "ctx"})

    def test_pi_install_writes_managed_extension(self):
        with tempfile.TemporaryDirectory() as tmp:
            agent_dir = Path(tmp) / "pi-agent"
            with Env(PI_CODING_AGENT_DIR=str(agent_dir)):
                visionctl.PROVIDERS["pi"].install()
                visionctl.PROVIDERS["pi"].install()

            extension = agent_dir / "extensions" / "vision-nvim.ts"
            source = extension.read_text(encoding="utf-8")

            self.assertIn("Managed by vision.nvim", source)
            self.assertIn(str(SCRIPT), source)
            self.assertIn('"before_agent_start"', source)
            self.assertIn('"hook", "pi"', source)
            self.assertIn('customType: "vision.nvim"', source)
            self.assertIn("display: false", source)

    def test_pi_wrap_returns_extension_payload(self):
        self.assertEqual(visionctl.PROVIDERS["pi"].wrap("ctx"), {"context": "ctx"})

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
