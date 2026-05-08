import json
import os
import sys
import tempfile
from pathlib import Path


DEFAULT_TIMEOUT_MS = 700
REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "bin" / "visionctl"


class VisionError(Exception):
    pass


def stderr(message):
    print(message, file=sys.stderr)


def compact_json(value):
    return json.dumps(value, separators=(",", ":"))


def read_json(path):
    if not path.exists():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
    except json.JSONDecodeError as exc:
        raise VisionError(f"invalid JSON in {path}: {exc}") from exc
    except OSError as exc:
        raise VisionError(f"failed to read {path}: {exc}") from exc

    if not isinstance(value, dict):
        raise VisionError(f"{path} must contain a JSON object")
    return value


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".vision.", suffix=".json", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2)
            handle.write("\n")
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise VisionError(f"failed to write {path}: {exc}") from exc


def read_text(path):
    if not path.exists():
        return ""
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise VisionError(f"failed to read {path}: {exc}") from exc


def write_text(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    suffix = path.suffix or ".tmp"
    fd, tmp = tempfile.mkstemp(prefix=".vision.", suffix=suffix, dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise VisionError(f"failed to write {path}: {exc}") from exc


def normalize_path(path, cwd=None):
    if not isinstance(path, str) or path.strip() == "":
        return None
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        candidate = Path(cwd or os.getcwd()) / candidate
    return str(candidate.resolve(strict=False))


def path_within(path, root):
    if path == root:
        return True
    if root == "/":
        return path.startswith("/")
    return path.startswith(root.rstrip("/") + "/")
