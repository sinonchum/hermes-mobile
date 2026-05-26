"""Skill management for Hermes Bridge."""

import os
import re
import shutil
from pathlib import Path


def execute_skill_manage(arguments: dict) -> str:
    """Advanced skill management: create, patch, edit, delete."""
    action = arguments.get("action", "")
    name = arguments.get("name", "")
    if not name:
        return "Error: Skill name required"

    skills_dir = Path(os.environ.get("HOME", "")) / ".hermes" / "skills"
    skills_dir.mkdir(parents=True, exist_ok=True)

    skill_file = skills_dir / f"{name}.md"
    skill_dir_file = skills_dir / name / "SKILL.md"

    if action == "create":
        content = arguments.get("content", "")
        if not content:
            return "Error: Content required for create"
        skill_file.write_text(content)
        return f"Skill '{name}' created at {skill_file}"

    elif action == "patch":
        old_string = arguments.get("old_string", "")
        new_string = arguments.get("new_string", "")
        if not old_string:
            return "Error: old_string required for patch"
        target = skill_file if skill_file.exists() else skill_dir_file
        if not target.exists():
            return f"Error: Skill '{name}' not found"
        content = target.read_text()
        if old_string not in content:
            return f"Error: Could not find text in skill '{name}'"
        target.write_text(content.replace(old_string, new_string, 1))
        return f"Skill '{name}' patched ✓"

    elif action == "edit":
        content = arguments.get("content", "")
        if not content:
            return "Error: Content required for edit"
        target = skill_file if skill_file.exists() else skill_dir_file
        if not target.exists():
            return f"Error: Skill '{name}' not found"
        target.write_text(content)
        return f"Skill '{name}' updated ✓"

    elif action == "delete":
        deleted = False
        if skill_file.exists():
            skill_file.unlink()
            deleted = True
        if skill_dir_file.exists():
            shutil.rmtree(skill_dir_file.parent)
            deleted = True
        return f"Skill '{name}' deleted ✓" if deleted else f"Error: Skill '{name}' not found"

    else:
        return f"Error: Unknown action '{action}'"
