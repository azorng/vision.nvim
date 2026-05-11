from contextlib import contextmanager
from pathlib import Path

from .common import VisionError, normalize_path, path_within


BYTE_LIMIT = 12000
SELECTION_FALLBACK_LIMIT = 4000


LANGUAGE_OVERRIDES = {
    ".bash": "bash",
    ".cjs": "javascript",
    ".cts": "typescript",
    ".h": "c",
    ".hpp": "cpp",
    ".js": "javascript",
    ".json": "json",
    ".jsx": "jsx",
    ".lua": "lua",
    ".md": "markdown",
    ".mjs": "javascript",
    ".py": "python",
    ".sh": "bash",
    ".ts": "typescript",
    ".tsx": "tsx",
    ".yaml": "yaml",
    ".yml": "yaml",
}


def as_string(value):
    return value if isinstance(value, str) else None


def display_path(path, root):
    if not isinstance(path, str):
        return None
    normalized = normalize_path(path)
    root = normalize_path(root) if isinstance(root, str) else None
    if normalized and root and path_within(normalized, root):
        relative = normalized[len(root):].lstrip("/")
        return relative or "."
    return normalized or path


def language_for(path):
    suffix = Path(path).suffix.lower()
    if suffix in LANGUAGE_OVERRIDES:
        return LANGUAGE_OVERRIDES[suffix]
    if suffix.startswith(".") and suffix[1:].isalnum():
        return suffix[1:]
    return "text"


def fence_for(text):
    longest = 0
    current = 0
    for char in text:
        if char == "`":
            current += 1
            longest = max(longest, current)
        else:
            current = 0
    return "`" * max(3, longest + 1)


def truncate_utf8(text, limit):
    encoded = text.encode("utf-8")
    if len(encoded) <= limit:
        return text
    suffix = "\n[truncated]".encode("utf-8")
    budget = max(limit - len(suffix), 0)
    return encoded[:budget].decode("utf-8", "ignore") + suffix.decode("utf-8")


def human_line(value):
    return int(value) + 1 if isinstance(value, int) else 1


def human_col(value):
    return int(value) + 1 if isinstance(value, int) else 1


def diagnostic_lines(items, root, current_display):
    if not isinstance(items, list):
        return []

    rendered = []
    for item in items:
        if not isinstance(item, dict):
            continue
        message = as_string(item.get("message")) or ""
        severity = (as_string(item.get("severity")) or "information").upper()
        location = f"Line {human_line(item.get('start_line'))}, Column {human_col(item.get('start_col'))}"
        item_path = display_path(item.get("file"), root)
        if item_path and item_path != current_display:
            location = f"{item_path}: {location}"
        rendered.append(f"[{severity}] {location}: {message.replace(chr(10), ' ').strip()}")
    return rendered


class StructuredText:
    def __init__(self):
        self.lines = []
        self.level = 0

    def blank(self):
        self.lines.append("")

    def line(self, text):
        self.lines.append("  " * self.level + text)

    @contextmanager
    def block(self, tag):
        self.line(f"<{tag}>")
        self.level += 1
        try:
            yield
        finally:
            self.level -= 1
            self.line(f"</{tag}>")

    def render(self):
        return "\n".join(self.lines)


def render_current_file(doc, current_display):
    doc.blank()
    with doc.block("current-file"):
        doc.line(f"Path: {current_display}")


def render_cursor(doc, cursor):
    doc.blank()
    with doc.block("cursor-data"):
        doc.line(f"Line: {human_line(cursor.get('line'))}")
        doc.line(f"Column: {human_col(cursor.get('col'))}")


def render_current_line(doc, current_line):
    doc.blank()
    with doc.block("line-content"):
        doc.line(current_line.replace(chr(10), " ").strip())


def render_visual_selection(doc, selection_display, range_value, selected_text):
    fence = fence_for(selected_text)
    language = language_for(selection_display)
    start_line = human_line(range_value.get("start_line"))
    end_line = human_line(range_value.get("end_line"))

    with doc.block("visual-selection"):
        doc.line(f"{fence}{language} {selection_display} (lines {start_line}-{end_line})")
        for line in selected_text.splitlines():
            doc.line(line)
        doc.line(fence)


def render_diagnostics(doc, diagnostics):
    if not diagnostics:
        return

    doc.blank()
    with doc.block("linter-errors"):
        for line in diagnostics:
            doc.line(line)


def render_once(envelope, root, selection_limit=None, include_diagnostics=True):
    if not isinstance(envelope, dict):
        raise VisionError("attachment envelope must be an object")

    workspace = envelope.get("workspace") if isinstance(envelope.get("workspace"), dict) else {}
    root = as_string(root) or as_string(workspace.get("cwd"))
    attachment = envelope.get("attachment")
    context = envelope.get("context") if isinstance(envelope.get("context"), dict) else {}
    if not isinstance(attachment, dict) or attachment.get("type") != "visual_selection":
        raise VisionError("attachment envelope is missing visual selection")

    file_path = as_string(attachment.get("file"))
    if file_path is None:
        raise VisionError("visual selection is missing file")

    selected_text = as_string(attachment.get("text")) or ""
    if selection_limit is not None:
        selected_text = truncate_utf8(selected_text, selection_limit)

    current_file = as_string(context.get("current_file"))
    current_display = display_path(current_file, root) if current_file else display_path(file_path, root)
    selection_display = display_path(file_path, root) or file_path
    range_value = attachment.get("range") if isinstance(attachment.get("range"), dict) else {}
    has_selection = attachment.get("selected") is not False
    diagnostics = diagnostic_lines(context.get("diagnostics"), root, current_display) if include_diagnostics else []

    doc = StructuredText()
    with doc.block("additional-data"):
        doc.line("Below is context that may help with the user query. Ignore if not relevant")

        if current_file:
            render_current_file(doc, current_display)

        cursor = context.get("cursor")
        if isinstance(cursor, dict):
            render_cursor(doc, cursor)

        current_line = as_string(context.get("current_line"))
        if current_line:
            render_current_line(doc, current_line)

        if has_selection or diagnostics:
            doc.blank()
            with doc.block("attached-files"):
                if has_selection:
                    render_visual_selection(doc, selection_display, range_value, selected_text)
                render_diagnostics(doc, diagnostics)

    return doc.render()


def render_context(envelope, root):
    attempts = [
        (None, True),
        (SELECTION_FALLBACK_LIMIT, True),
        (SELECTION_FALLBACK_LIMIT, False),
        (1000, False),
    ]
    for selection_limit, include_diagnostics in attempts:
        rendered = render_once(envelope, root, selection_limit, include_diagnostics)
        if len(rendered.encode("utf-8")) <= BYTE_LIMIT:
            return rendered
    raise VisionError("rendered context exceeded byte limit")
