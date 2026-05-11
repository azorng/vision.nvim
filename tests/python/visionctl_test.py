import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "bin" / "visionctl"

sys.path.insert(0, str(ROOT))
import visionctl
import visionctl.session


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


def write_session_records(directory, records):
    for record in records:
        (directory / (record["id"] + ".json")).write_text(json.dumps(record), encoding="utf-8")


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

    def test_attach_context_renders_paths_relative_to_agent_cwd(self):
        with tempfile.TemporaryDirectory() as tmp:
            agent_cwd = Path(tmp) / "repo"
            nvim_cwd = agent_cwd / "foo"
            file_path = nvim_cwd / "bar" / "baz.yaml"
            file_path.parent.mkdir(parents=True)
            envelope = {
                "schema": 1,
                "workspace": {
                    "cwd": str(nvim_cwd),
                    "roots": [str(nvim_cwd)],
                },
                "attachment": {
                    "type": "visual_selection",
                    "file": str(file_path),
                    "mode": "line",
                    "range": {
                        "start_line": 0,
                        "start_col": 0,
                        "end_line": 0,
                        "end_col": 11,
                    },
                    "text": "name: value",
                },
                "context": {
                    "current_file": str(file_path),
                    "diagnostics": [],
                },
            }

            with patch("visionctl.session.select_session", return_value={"cwd": str(nvim_cwd)}), patch(
                "visionctl.session.request", return_value=envelope
            ):
                rendered = visionctl.session.attach_context(str(agent_cwd))

            self.assertIn("Path: foo/bar/baz.yaml", rendered)
            self.assertIn("```yaml foo/bar/baz.yaml (lines 1-1)", rendered)
            self.assertNotIn("Path: bar/baz.yaml", rendered)

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
            write_session_records(sessions, records)

            with Env(VISION_NVIM_DATA_HOME=str(data)):
                selected = visionctl.select_session(str(nested))

            self.assertEqual(selected["id"], "nested")

    def test_select_session_prefers_latest_visual_activity_for_same_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            data = tmp_path / "data"
            sessions = data / "sessions"
            sessions.mkdir(parents=True)
            root = tmp_path / "repo"
            root.mkdir()

            records = [
                {
                    "schema": 1,
                    "id": "older-selection-newer-session",
                    "pid": os.getpid(),
                    "cwd": str(root),
                    "roots": [str(root)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 1},
                    "token": "x",
                    "started_at": "2026-05-11T12:00:00.000Z",
                    "last_visual_at": "2026-05-11T12:01:00.000Z",
                },
                {
                    "schema": 1,
                    "id": "latest-selection",
                    "pid": os.getpid(),
                    "cwd": str(root),
                    "roots": [str(root)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 2},
                    "token": "x",
                    "started_at": "2026-05-11T11:00:00.000Z",
                    "last_visual_at": "2026-05-11T12:02:00.000Z",
                },
            ]
            write_session_records(sessions, records)

            with Env(VISION_NVIM_DATA_HOME=str(data)):
                selected = visionctl.select_session(str(root))

            self.assertEqual(selected["id"], "latest-selection")

    def test_select_session_prefers_latest_visual_activity_over_longer_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            data = tmp_path / "data"
            sessions = data / "sessions"
            sessions.mkdir(parents=True)
            parent = tmp_path / "repo"
            nested = parent / "nested"
            nested.mkdir(parents=True)

            records = [
                {
                    "schema": 1,
                    "id": "latest-selection",
                    "pid": os.getpid(),
                    "cwd": str(parent),
                    "roots": [str(parent)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 1},
                    "token": "x",
                    "started_at": "2026-05-11T11:00:00.000Z",
                    "last_visual_at": "2026-05-11T12:02:00.000Z",
                },
                {
                    "schema": 1,
                    "id": "longer-root",
                    "pid": os.getpid(),
                    "cwd": str(nested),
                    "roots": [str(nested)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 2},
                    "token": "x",
                    "started_at": "2026-05-11T12:00:00.000Z",
                    "last_visual_at": "2026-05-11T12:01:00.000Z",
                },
            ]
            write_session_records(sessions, records)

            with Env(VISION_NVIM_DATA_HOME=str(data)):
                selected = visionctl.select_session(str(nested))

            self.assertEqual(selected["id"], "latest-selection")

    def test_select_session_prefers_active_visual_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            data = tmp_path / "data"
            sessions = data / "sessions"
            sessions.mkdir(parents=True)
            root = tmp_path / "repo"
            root.mkdir()

            records = [
                {
                    "schema": 1,
                    "id": "inactive-latest",
                    "pid": os.getpid(),
                    "cwd": str(root),
                    "roots": [str(root)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 1},
                    "token": "x",
                    "started_at": "2026-05-11T12:00:00.000Z",
                    "last_visual_at": "2026-05-11T12:02:00.000Z",
                    "visual_active": False,
                },
                {
                    "schema": 1,
                    "id": "active-selection",
                    "pid": os.getpid(),
                    "cwd": str(root),
                    "roots": [str(root)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 2},
                    "token": "x",
                    "started_at": "2026-05-11T11:00:00.000Z",
                    "last_visual_at": "2026-05-11T12:01:00.000Z",
                    "visual_active": True,
                },
            ]
            write_session_records(sessions, records)

            with Env(VISION_NVIM_DATA_HOME=str(data)):
                selected = visionctl.select_session(str(root))

            self.assertEqual(selected["id"], "active-selection")

    def test_select_session_prefers_latest_visual_activity_without_root_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            data = tmp_path / "data"
            sessions = data / "sessions"
            sessions.mkdir(parents=True)
            agent_root = tmp_path / "agent-repo"
            visual_root = tmp_path / "visual-repo"
            agent_root.mkdir()
            visual_root.mkdir()

            records = [
                {
                    "schema": 1,
                    "id": "agent-root",
                    "pid": os.getpid(),
                    "cwd": str(agent_root),
                    "roots": [str(agent_root)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 1},
                    "token": "x",
                    "started_at": "2026-05-11T12:00:00.000Z",
                },
                {
                    "schema": 1,
                    "id": "latest-visual-root",
                    "pid": os.getpid(),
                    "cwd": str(visual_root),
                    "roots": [str(visual_root)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 2},
                    "token": "x",
                    "started_at": "2026-05-11T11:00:00.000Z",
                    "last_visual_at": "2026-05-11T12:02:00.000Z",
                    "visual_active": True,
                },
            ]
            write_session_records(sessions, records)

            with Env(VISION_NVIM_DATA_HOME=str(data)):
                selected = visionctl.select_session(str(agent_root))

            self.assertEqual(selected["id"], "latest-visual-root")

    def test_select_session_refreshes_live_visual_state_before_ranking(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            data = tmp_path / "data"
            sessions = data / "sessions"
            sessions.mkdir(parents=True)
            agent_root = tmp_path / "agent-repo"
            visual_root = tmp_path / "visual-repo"
            agent_root.mkdir()
            visual_root.mkdir()

            records = [
                {
                    "schema": 1,
                    "id": "stale-record-winner",
                    "pid": os.getpid(),
                    "cwd": str(agent_root),
                    "roots": [str(agent_root)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 1},
                    "token": "x",
                    "started_at": "2026-05-11T12:00:00.000Z",
                    "last_visual_at": "2026-05-11T12:05:00.000Z",
                    "visual_active": True,
                },
                {
                    "schema": 1,
                    "id": "live-visual",
                    "pid": os.getpid(),
                    "cwd": str(visual_root),
                    "roots": [str(visual_root)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 2},
                    "token": "x",
                    "started_at": "2026-05-11T11:00:00.000Z",
                    "last_visual_at": "2026-05-11T12:01:00.000Z",
                    "visual_active": False,
                },
            ]
            write_session_records(sessions, records)

            live_states = {
                "stale-record-winner": {
                    "visual_active": False,
                    "last_visual_at": "2026-05-11T12:05:00.000Z",
                    "cwd": str(agent_root),
                    "roots": [str(agent_root)],
                },
                "live-visual": {
                    "visual_active": True,
                    "last_visual_at": "2026-05-11T12:06:00.000Z",
                    "cwd": str(visual_root),
                    "roots": [str(visual_root)],
                },
            }

            def fake_request(record, method, timeout_ms=700):
                self.assertEqual(method, "vision.visual_state")
                self.assertLessEqual(timeout_ms, 700)
                return live_states[record["id"]]

            with Env(VISION_NVIM_DATA_HOME=str(data)), patch("visionctl.session.request", side_effect=fake_request):
                selected = visionctl.select_session(str(agent_root))

            self.assertEqual(selected["id"], "live-visual")
            self.assertEqual(selected["visual_active"], True)
            self.assertEqual(selected["cwd"], str(visual_root.resolve(strict=False)))

    def test_select_session_does_not_let_stale_unrefreshable_records_win(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            data = tmp_path / "data"
            sessions = data / "sessions"
            sessions.mkdir(parents=True)
            old_root = tmp_path / "old-repo"
            live_root = tmp_path / "live-repo"
            old_root.mkdir()
            live_root.mkdir()

            records = [
                {
                    "schema": 1,
                    "id": "old-stale-active",
                    "pid": os.getpid(),
                    "cwd": str(old_root),
                    "roots": [str(old_root)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 1},
                    "token": "x",
                    "started_at": "2026-05-11T12:00:00.000Z",
                    "last_visual_at": "2026-05-11T12:07:00.000Z",
                    "visual_active": True,
                },
                {
                    "schema": 1,
                    "id": "live-active",
                    "pid": os.getpid(),
                    "cwd": str(live_root),
                    "roots": [str(live_root)],
                    "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 2},
                    "token": "x",
                    "started_at": "2026-05-11T11:00:00.000Z",
                    "last_visual_at": "2026-05-11T12:01:00.000Z",
                    "visual_active": False,
                },
            ]
            write_session_records(sessions, records)

            def fake_request(record, method, timeout_ms=700):
                self.assertEqual(method, "vision.visual_state")
                if record["id"] == "old-stale-active":
                    raise visionctl.session.VisionError("unknown method: vision.visual_state")
                return {
                    "visual_active": True,
                    "last_visual_at": "2026-05-11T12:06:00.000Z",
                    "cwd": str(live_root),
                    "roots": [str(live_root)],
                }

            with Env(VISION_NVIM_DATA_HOME=str(data)), patch("visionctl.session.request", side_effect=fake_request):
                selected = visionctl.select_session(str(old_root))

            self.assertEqual(selected["id"], "live-active")
            self.assertEqual(selected["visual_active"], True)


if __name__ == "__main__":
    unittest.main()
