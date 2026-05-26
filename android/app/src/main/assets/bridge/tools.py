"""Tool definitions and execution for Hermes Bridge."""

import os
import re
import json
import subprocess
from pathlib import Path
from .config import PREFIX, HOME

# ── Tool Definitions ────────────────────────────────────────
TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "terminal",
            "description": "Execute a shell command on the device. Returns stdout+stderr.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Shell command to execute"},
                    "timeout": {"type": "integer", "description": "Timeout in seconds", "default": 30},
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a text file from the device.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute file path"},
                    "limit": {"type": "integer", "description": "Max lines to read", "default": 200},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write content to a file (creates or overwrites).",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute file path"},
                    "content": {"type": "string", "description": "File content"},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the web for information. Returns top results.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query"},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_scrape",
            "description": "Fetch a URL and extract readable text content.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "URL to fetch"},
                    "max_chars": {"type": "integer", "description": "Max characters", "default": 8000},
                },
                "required": ["url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "skill_list",
            "description": "List installed skills.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "skill_view",
            "description": "Read a skill's content by name.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Skill name"},
                },
                "required": ["name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "skill_create",
            "description": "Create or update a skill.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Skill name"},
                    "content": {"type": "string", "description": "Full SKILL.md content"},
                },
                "required": ["name", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "memory",
            "description": "Manage persistent memory. Use add/replace/remove.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["add", "replace", "remove"]},
                    "content": {"type": "string"},
                    "old_text": {"type": "string"},
                },
                "required": ["action"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "session_search",
            "description": "Search past conversations.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "limit": {"type": "integer", "default": 3},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "skill_manage",
            "description": "Advanced skill management: create, patch, edit, delete.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["create", "patch", "edit", "delete"]},
                    "name": {"type": "string"},
                    "content": {"type": "string"},
                    "old_string": {"type": "string"},
                    "new_string": {"type": "string"},
                },
                "required": ["action", "name"],
            },
        },
    },
]


# ── Tool Execution ──────────────────────────────────────────
def execute_tool(name: str, arguments: dict) -> str:
    """Execute a tool call and return the result as a string."""
    try:
        if name == "terminal":
            return _exec_terminal(arguments)
        elif name == "read_file":
            return _exec_read_file(arguments)
        elif name == "write_file":
            return _exec_write_file(arguments)
        elif name == "web_search":
            return _exec_web_search(arguments)
        elif name == "web_scrape":
            return _exec_web_scrape(arguments)
        elif name == "skill_list":
            return _exec_skill_list()
        elif name == "skill_view":
            return _exec_skill_view(arguments)
        elif name == "skill_create":
            return _exec_skill_create(arguments)
        elif name == "memory":
            from .memory import execute_memory
            return execute_memory(arguments)
        elif name == "session_search":
            from .sessions import execute_session_search
            return execute_session_search(arguments)
        elif name == "skill_manage":
            from .skills import execute_skill_manage
            return execute_skill_manage(arguments)
        else:
            return f"Unknown tool: {name}"
    except subprocess.TimeoutExpired:
        return "Error: Command timed out"
    except Exception as e:
        return f"Error: {str(e)}"


def _exec_terminal(arguments: dict) -> str:
    cmd = arguments.get("command", "")
    timeout = arguments.get("timeout", 30)
    result = subprocess.run(
        cmd, shell=True, capture_output=True, text=True, timeout=timeout,
        env={**os.environ, "PREFIX": PREFIX, "HOME": HOME,
             "PATH": f"{PREFIX}/bin:{os.environ.get('PATH', '')}",
             "LANG": "en_US.UTF-8"},
    )
    output = result.stdout + result.stderr
    if len(output) > 8000:
        output = output[:8000] + "\n... (truncated)"
    return output if output else f"(exit code: {result.returncode})"


def _exec_read_file(arguments: dict) -> str:
    path = arguments.get("path", "")
    limit = arguments.get("limit", 200)
    p = Path(path)
    if not p.exists():
        return f"Error: File not found: {path}"
    lines = p.read_text().splitlines()[:limit]
    return "\n".join(f"{i+1}|{line}" for i, line in enumerate(lines))


def _exec_write_file(arguments: dict) -> str:
    path = arguments.get("path", "")
    content = arguments.get("content", "")
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
    return f"Written {len(content)} chars to {path}"


def _exec_web_search(arguments: dict) -> str:
    query = arguments.get("query", "")
    try:
        import urllib.parse
        encoded = urllib.parse.quote(query)
        result = subprocess.run(
            ["curl", "-sL", "-A", "Mozilla/5.0", f"https://lite.duckduckgo.com/lite/?q={encoded}"],
            capture_output=True, text=True, timeout=15,
        )
        snippets = re.findall(r'<td[^>]*class="result-snippet"[^>]*>(.*?)</td>', result.stdout, re.DOTALL)
        clean = [re.sub(r'<[^>]+>', '', s).strip() for s in snippets[:5]]
        return "\n".join(f"• {s}" for s in clean if s) or "No results found."
    except Exception as e:
        return f"Search error: {e}"


def _exec_web_scrape(arguments: dict) -> str:
    url = arguments.get("url", "")
    max_chars = arguments.get("max_chars", 8000)
    if not url:
        return "Error: No URL provided"
    try:
        result = subprocess.run(
            ["curl", "-sL", "-A", "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36",
             "--max-time", "15", url],
            capture_output=True, text=True, timeout=20,
        )
        if result.returncode != 0:
            return f"Error: curl failed (exit {result.returncode})"
        html = result.stdout
        if not html:
            return "Error: Empty response"

        try:
            from lxml import html as lxml_html
            tree = lxml_html.fromstring(html)
            for tag in tree.xpath('//script|//style|//nav|//footer|//header'):
                tag.getparent().remove(tag)
            text = tree.text_content()
        except ImportError:
            text = re.sub(r'<script[^>]*>.*?</script>', '', html, flags=re.DOTALL | re.IGNORECASE)
            text = re.sub(r'<style[^>]*>.*?</style>', '', text, flags=re.DOTALL | re.IGNORECASE)
            text = re.sub(r'<[^>]+>', ' ', text)
            text = re.sub(r'&[a-zA-Z]+;', ' ', text)
            text = re.sub(r'\s+', ' ', text)

        text = text.strip()
        if len(text) > max_chars:
            text = text[:max_chars] + "\n... (truncated)"
        return text if text else "No readable content found."
    except subprocess.TimeoutExpired:
        return "Error: Request timed out"
    except Exception as e:
        return f"Scrape error: {e}"


def _exec_skill_list() -> str:
    skills_dir = Path(HOME) / ".hermes" / "skills"
    if not skills_dir.exists():
        return "No skills directory found."
    skills = []
    for f in sorted(skills_dir.iterdir()):
        if f.is_file() and f.suffix == ".md":
            try:
                first_lines = f.read_text().split("\n")[:3]
                desc = ""
                for line in first_lines:
                    if line.strip() and not line.startswith("#") and not line.startswith("---"):
                        desc = line.strip()[:80]
                        break
                skills.append(f"• {f.stem} — {desc}" if desc else f"• {f.stem}")
            except Exception:
                skills.append(f"• {f.stem}")
        elif f.is_dir() and (f / "SKILL.md").exists():
            skills.append(f"• {f.name}/")
    return "\n".join(skills) if skills else "No skills installed."


def _exec_skill_view(arguments: dict) -> str:
    skill_name = arguments.get("name", "")
    if not skill_name:
        return "Error: No skill name provided"
    skills_dir = Path(HOME) / ".hermes" / "skills"
    for candidate in [skills_dir / f"{skill_name}.md", skills_dir / skill_name / "SKILL.md"]:
        if candidate.exists():
            content = candidate.read_text()
            if len(content) > 8000:
                content = content[:8000] + "\n... (truncated)"
            return content
    return f"Skill '{skill_name}' not found."


def _exec_skill_create(arguments: dict) -> str:
    skill_name = arguments.get("name", "")
    content = arguments.get("content", "")
    if not skill_name or not content:
        return "Error: Both name and content are required"
    safe_name = re.sub(r'[^a-zA-Z0-9_-]', '-', skill_name).strip('-')
    if not safe_name:
        return "Error: Invalid skill name"
    skills_dir = Path(HOME) / ".hermes" / "skills"
    skills_dir.mkdir(parents=True, exist_ok=True)
    skill_file = skills_dir / f"{safe_name}.md"
    skill_file.write_text(content)
    return f"Skill '{safe_name}' saved to {skill_file}"
