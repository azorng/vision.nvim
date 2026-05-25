import json
import sys

from .common import DEFAULT_TIMEOUT_MS, VisionError, compact_json, stderr
from .providers import PROVIDERS
from .session import attach_context


def parse_hook_payload(allow_promptless=False):
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    if allow_promptless:
        if "prompt" in payload and not isinstance(payload.get("prompt"), str):
            return None
    elif not isinstance(payload.get("prompt"), str):
        return None
    payload = dict(payload)
    payload.setdefault("prompt", "")
    return payload


def cmd_hook(argv):
    if len(argv) != 1 or argv[0] not in PROVIDERS:
        return 0

    provider = PROVIDERS[argv[0]]
    try:
        payload = parse_hook_payload(provider.accept_promptless_payload())
        if payload is None:
            return 0
        context = attach_context(provider.resolve_cwd(payload), DEFAULT_TIMEOUT_MS)
        if context is None:
            return 0
        sys.stdout.write(compact_json(provider.wrap(context)))
        return 0
    except Exception:
        return 0


def provider_names():
    return "|".join(PROVIDERS.keys())


def cmd_install(argv):
    if len(argv) != 1 or argv[0] not in PROVIDERS:
        raise VisionError(f"usage: visionctl install <{provider_names()}>")
    PROVIDERS[argv[0]].install()
    return 0


COMMANDS = {
    "hook": cmd_hook,
    "install": cmd_install,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        stderr("usage: visionctl <hook|install> ...")
        return 2

    command = argv[0]
    try:
        return COMMANDS[command](argv[1:])
    except VisionError as exc:
        stderr(str(exc))
        return 1
    except Exception as exc:
        stderr("unexpected error: " + str(exc))
        return 1
