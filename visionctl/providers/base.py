import os
from dataclasses import dataclass

from ..common import VisionError


@dataclass(frozen=True)
class Provider:
    name: str

    def resolve_cwd(self, payload):
        return os.getcwd()

    def accept_promptless_payload(self):
        return False

    def install(self):
        raise VisionError("unknown provider: " + self.name)


def payload_cwd(payload):
    cwd = payload.get("cwd") if isinstance(payload, dict) else None
    if isinstance(cwd, str) and cwd.strip():
        return cwd
    return None
