from .claude import ClaudeProvider
from .codex import CodexProvider
from .opencode import OpenCodeProvider


PROVIDERS = {
    "codex": CodexProvider(),
    "claude": ClaudeProvider(),
    "opencode": OpenCodeProvider(),
}


__all__ = ["PROVIDERS"]
