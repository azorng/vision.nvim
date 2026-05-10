import json
import os
from pathlib import Path

from ..common import SCRIPT_PATH, normalize_path, write_text
from .base import Provider, payload_cwd


PI_EXTENSION_FILENAME = "vision-nvim.ts"


def pi_agent_dir():
    override = os.environ.get("PI_CODING_AGENT_DIR")
    if override:
        return Path(normalize_path(override))
    return Path.home() / ".pi" / "agent"


def pi_extension_source():
    script = json.dumps(str(SCRIPT_PATH))
    return f"""// Managed by vision.nvim. Re-run :VisionInstall pi to refresh this file.
import {{ spawnSync }} from "node:child_process"

const VISIONCTL = {script}

function extractContext(stdout) {{
  const text = typeof stdout === "string" ? stdout.trim() : ""
  if (!text) return ""
  try {{
    const payload = JSON.parse(text)
    if (typeof payload?.context === "string") return payload.context
    const hookOutput = payload?.hookSpecificOutput
    if (typeof hookOutput?.additionalContext === "string") return hookOutput.additionalContext
  }} catch {{
  }}
  return ""
}}

function visionContext(event, ctx) {{
  const cwd = typeof ctx?.cwd === "string" && ctx.cwd
    ? ctx.cwd
    : typeof event?.systemPromptOptions?.cwd === "string" && event.systemPromptOptions.cwd
      ? event.systemPromptOptions.cwd
      : process.cwd()
  const payload = {{
    prompt: typeof event?.prompt === "string" ? event.prompt : "",
    cwd,
  }}
  const result = spawnSync(VISIONCTL, ["hook", "pi"], {{
    cwd,
    input: JSON.stringify(payload),
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
  }})
  if (result.error || result.status !== 0) return ""
  return extractContext(result.stdout)
}}

export default function (pi) {{
  pi.on("before_agent_start", async (event, ctx) => {{
    try {{
      const context = visionContext(event, ctx)
      if (!context) return
      return {{
        message: {{
          customType: "vision.nvim",
          content: context,
          display: false,
        }},
      }}
    }} catch {{
    }}
  }})
}}
"""


class PiProvider(Provider):
    def __init__(self):
        super().__init__("pi")

    def resolve_cwd(self, payload):
        return payload_cwd(payload) or super().resolve_cwd(payload)

    def wrap(self, context):
        return {
            "context": context,
        }

    def install(self):
        root = pi_agent_dir()
        write_text(root / "extensions" / PI_EXTENSION_FILENAME, pi_extension_source())
