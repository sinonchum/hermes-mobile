"""Persistent memory system for Hermes Bridge."""

import os
from pathlib import Path

MEMORY_FILE = Path(os.environ.get("HOME", "")) / ".hermes" / "memory.md"


def execute_memory(arguments: dict) -> str:
    """Manage persistent memory stored in ~/.hermes/memory.md"""
    MEMORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    action = arguments.get("action", "")

    if action == "add":
        content = arguments.get("content", "").strip()
        if not content:
            return "Error: No content to add"
        existing = MEMORY_FILE.read_text() if MEMORY_FILE.exists() else ""
        if existing and not existing.endswith("\n"):
            existing += "\n"
        MEMORY_FILE.write_text(existing + content + "\n")
        return f"Saved to memory: {content[:80]}..."

    elif action == "replace":
        old_text = arguments.get("old_text", "")
        new_content = arguments.get("content", "")
        if not old_text:
            return "Error: old_text required for replace"
        if not MEMORY_FILE.exists():
            return "Error: Memory file is empty"
        existing = MEMORY_FILE.read_text()
        if old_text not in existing:
            return f"Error: Could not find '{old_text[:50]}' in memory"
        MEMORY_FILE.write_text(existing.replace(old_text, new_content, 1))
        return f"Memory updated: replaced '{old_text[:50]}'"

    elif action == "remove":
        old_text = arguments.get("old_text", "")
        if not old_text:
            return "Error: old_text required for remove"
        if not MEMORY_FILE.exists():
            return "Error: Memory file is empty"
        existing = MEMORY_FILE.read_text()
        if old_text not in existing:
            return f"Error: Could not find '{old_text[:50]}' in memory"
        lines = existing.split("\n")
        new_lines = [l for l in lines if old_text not in l]
        MEMORY_FILE.write_text("\n".join(new_lines))
        return f"Memory removed: '{old_text[:50]}'"

    else:
        return f"Error: Unknown memory action '{action}'"
