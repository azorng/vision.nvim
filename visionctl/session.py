import json
import os
import socket
import sys
from datetime import datetime, timezone
from pathlib import Path

from .common import DEFAULT_TIMEOUT_MS, VisionError, compact_json, normalize_path, path_within
from .render import render_context


def data_home():
    override = os.environ.get("VISION_NVIM_DATA_HOME")
    if override:
        return Path(normalize_path(override))

    xdg = os.environ.get("XDG_DATA_HOME")
    if sys.platform.startswith("linux") and xdg:
        return Path(normalize_path(xdg)) / "vision.nvim"

    return Path.home() / ".local" / "share" / "vision.nvim"


def sessions_dir():
    return data_home() / "sessions"


def parse_time(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def epoch_ms(value):
    parsed = parse_time(value)
    if parsed is None:
        return -1
    return int(parsed.timestamp() * 1000)


def process_exists(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def root_matches(record, cwd):
    roots = record.get("roots")
    if not isinstance(roots, list):
        roots = [record.get("cwd")]

    winner = None
    for root in roots:
        normalized = normalize_path(root)
        if normalized and path_within(cwd, normalized):
            if winner is None or len(normalized) > len(winner):
                winner = normalized
    return winner


def load_sessions():
    directory = sessions_dir()
    if not directory.exists():
        return []

    records = []
    for path in sorted(directory.glob("*.json")):
        try:
            with path.open("r", encoding="utf-8") as handle:
                record = json.load(handle)
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(record, dict):
            continue

        if not process_exists(record.get("pid")):
            try:
                path.unlink()
            except OSError:
                pass
            continue

        record["_path"] = str(path)
        records.append(record)
    return records


def refresh_session_record(record, timeout_ms):
    try:
        state = request(record, "vision.visual_state", timeout_ms)
    except VisionError:
        return dict(record), False

    if not isinstance(state, dict):
        return dict(record), False

    refreshed = dict(record)
    if isinstance(state.get("visual_active"), bool):
        refreshed["visual_active"] = state["visual_active"]
    if "last_visual_at" in state and (
        state.get("last_visual_at") is None or parse_time(state.get("last_visual_at")) is not None
    ):
        refreshed["last_visual_at"] = state.get("last_visual_at")

    cwd = normalize_path(state.get("cwd"))
    if cwd is not None:
        refreshed["cwd"] = cwd

    roots = state.get("roots")
    if isinstance(roots, list):
        normalized_roots = []
        for root in roots:
            normalized = normalize_path(root)
            if normalized is not None:
                normalized_roots.append(normalized)
        if normalized_roots:
            refreshed["roots"] = normalized_roots

    return refreshed, True


def select_session(cwd, timeout_ms=DEFAULT_TIMEOUT_MS):
    normalized_cwd = normalize_path(cwd)
    if normalized_cwd is None:
        raise VisionError("cwd must be a non-empty path")

    records = [refresh_session_record(record, timeout_ms) for record in load_sessions()]
    has_live_state = any(refreshed for _, refreshed in records)

    best = None
    for record, refreshed in records:
        root = root_matches(record, normalized_cwd)
        trust_visual_state = refreshed or not has_live_state
        visual_at = epoch_ms(record.get("last_visual_at")) if trust_visual_state else -1
        visual_active = trust_visual_state and record.get("visual_active") is True
        has_visual_activity = visual_active or visual_at >= 0
        if root is None and not has_visual_activity:
            continue

        candidate = (
            1 if visual_active else 0,
            1 if visual_at >= 0 else 0,
            visual_at,
            1 if root is not None else 0,
            len(root or ""),
            epoch_ms(record.get("started_at")),
            str(record.get("id", "")),
            record,
        )
        if best is None or candidate[:-1] > best[:-1]:
            best = candidate

    if best is None:
        return None
    return best[-1]


def request(record, method, timeout_ms=DEFAULT_TIMEOUT_MS):
    transport = record.get("transport")
    if not isinstance(transport, dict):
        raise VisionError("session transport is missing")
    token = record.get("token")
    if not isinstance(token, str) or token == "":
        raise VisionError("session token is missing")

    kind = transport.get("kind")
    if kind == "socket":
        path = transport.get("path")
        if not isinstance(path, str) or path == "":
            raise VisionError("socket path is missing")
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        endpoint = path
    elif kind == "tcp":
        host = transport.get("host")
        port = transport.get("port")
        if not isinstance(host, str) or not isinstance(port, int):
            raise VisionError("tcp endpoint is invalid")
        client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        endpoint = (host, port)
    else:
        raise VisionError("unknown transport kind")

    client.settimeout(timeout_ms / 1000)
    try:
        client.connect(endpoint)
        payload = compact_json({
            "id": 1,
            "method": method,
            "token": token,
            "params": {},
        }).encode("utf-8") + b"\n"
        client.sendall(payload)

        chunks = []
        while True:
            chunk = client.recv(4096)
            if chunk == b"":
                raise VisionError("service response was not newline terminated")
            chunks.append(chunk)
            if b"\n" in chunk:
                break
    except OSError as exc:
        raise VisionError(f"failed to reach Neovim session: {exc}") from exc
    finally:
        client.close()

    line = b"".join(chunks).split(b"\n", 1)[0]
    try:
        response = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise VisionError("service returned invalid JSON") from exc

    if not isinstance(response, dict):
        raise VisionError("service response must be an object")
    if response.get("id") != 1:
        raise VisionError("service response id did not match")
    if response.get("error") is not None:
        error = response.get("error")
        if isinstance(error, dict) and isinstance(error.get("message"), str):
            raise VisionError(error["message"])
        raise VisionError("service request failed")
    return response.get("result")


def attach_context(cwd, timeout_ms=DEFAULT_TIMEOUT_MS):
    render_root = normalize_path(cwd)
    record = select_session(render_root, timeout_ms)
    if record is None:
        return None
    envelope = request(record, "vision.consume_attachment", timeout_ms)
    if envelope is None:
        return None
    return render_context(envelope, render_root)
