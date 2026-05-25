from .claude import ClaudeProvider
from .codex import CodexProvider
from .cursor import CursorProvider
from .opencode import OpenCodeProvider
from .pi import PiProvider


PROVIDERS = {
    "codex": CodexProvider(),
    "claude": ClaudeProvider(),
    "cursor": CursorProvider(),
    "opencode": OpenCodeProvider(),
    "pi": PiProvider(),
}


__all__ = ["PROVIDERS"]
