"""
Hermes Bridge Server — Lightweight API server for Hermes Mobile.
Runs inside Termux on Android, bridges Flutter UI to LLM + tools.

Endpoints:
  GET  /api/health         — Health check
  POST /api/chat           — Send message, get response (non-streaming)
  WS   /ws/chat            — WebSocket for streaming chat
  POST /api/bootstrap/check — Check environment status
"""

import asyncio
import json
import os
import sys
import logging
import signal
import subprocess
import traceback
from pathlib import Path
from datetime import datetime

# ── Logging ──────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("hermes-bridge")

# ── Config ───────────────────────────────────────────────────
HOST = os.environ.get("BRIDGE_HOST", "127.0.0.1")
PORT = int(os.environ.get("BRIDGE_PORT", "18923"))
PREFIX = os.environ.get("PREFIX", "")
HOME = os.environ.get("HOME", "")

# ── Lazy imports (avoid import errors before deps installed) ─
try:
    from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
    from fastapi.middleware.cors import CORSMiddleware
    from fastapi.responses import JSONResponse
    import uvicorn
    HAS_FASTAPI = True
except ImportError:
    HAS_FASTAPI = False
    logger.warning("FastAPI not installed. Run: pip install fastapi uvicorn websockets")

try:
    from openai import OpenAI
    HAS_OPENAI = True
except ImportError:
    HAS_OPENAI = False
    logger.warning("OpenAI not installed. Run: pip install openai")


# ── App ──────────────────────────────────────────────────────
app = FastAPI(title="Hermes Bridge", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── LLM Client ──────────────────────────────────────────────
def get_llm_client() -> "OpenAI | None":
    """Create OpenAI-compatible client. Supports cloud + local (PocketPal/Ollama)."""
    if not HAS_OPENAI:
        return None

    # Local model mode (PocketPal, Ollama, LM Studio, etc.)
    local_base = os.environ.get("LOCAL_LLM_URL")
    if local_base:
        # PocketPal: http://127.0.0.1:8080/v1
        # Ollama: http://127.0.0.1:11434/v1
        # LM Studio: http://127.0.0.1:1234/v1
        local_key = os.environ.get("LOCAL_LLM_KEY", "not-needed")
        return OpenAI(api_key=local_key, base_url=local_base)

    # Cloud mode (Nous API)
    api_key = os.environ.get("NOUS_API_KEY") or os.environ.get("OPENAI_API_KEY")
    base_url = os.environ.get("NOUS_API_BASE") or os.environ.get("OPENAI_BASE_URL")
    if not api_key:
        return None

    kwargs = {"api_key": api_key}
    if base_url:
        kwargs["base_url"] = base_url
    return OpenAI(**kwargs)


MODEL = os.environ.get("HERMES_MODEL", "gpt-4o-mini")

def get_active_model() -> str:
    """Return the active model identifier."""
    if os.environ.get("LOCAL_LLM_URL"):
        local_model = os.environ.get("LOCAL_LLM_MODEL", "local")
        return local_model
    return MODEL


def get_system_prompt() -> str:
    """Build system prompt with dynamic model name, memory, and skills."""
    active = get_active_model()

    # Inject current memory
    memory_context = load_memory_context()

    # Inject relevant skills
    skills_context = load_skills_context()

    prompt = f"""You are Hermes, an AI assistant running on a mobile device (Android).
You are powered by the {active} model.
You have access to the device's file system and shell through tool calls.
Be concise, helpful, and mobile-friendly in your responses.
When running terminal commands, explain what you're doing briefly.
When asked what model you are, answer that you are running on {active}.

══════════════════════════════════════════════
MEMORY (your persistent notes) [{len(memory_context)}/2000 chars]
══════════════════════════════════════════════
{memory_context if memory_context else "(empty — save important facts with memory tool)"}

══════════════════════════════════════════════
SKILLS (your learned procedures)
══════════════════════════════════════════════
{skills_context if skills_context else "(no skills installed)"}

## Critical Instructions
- You have PERSISTENT MEMORY. Use the memory tool to save: user preferences, environment details, tool quirks, stable conventions.
- Memory survives across sessions. Keep it compact — only facts that will matter later.
- When the user corrects you or states a preference, SAVE IT to memory immediately.
- After complex tasks (5+ tool calls), offer to save the approach as a skill with skill_create.
- When you discover a new way to do something, save it as a skill.
- Before answering, scan your memory and skills for relevant context.
- If user references past conversations, check memory first."""
    return prompt


def load_memory_context() -> str:
    """Load persistent memory from ~/.hermes/memory.md"""
    try:
        mem_file = Path(HOME) / ".hermes" / "memory.md"
        if mem_file.exists():
            content = mem_file.read_text().strip()
            if len(content) > 2000:
                content = content[:2000] + "\n... (truncated)"
            return content
    except Exception:
        pass
    return ""


def load_skills_context() -> str:
    """Load installed skill descriptions for system prompt."""
    try:
        skills_dir = Path(HOME) / ".hermes" / "skills"
        if not skills_dir.exists():
            return ""
        entries = []
        for f in sorted(skills_dir.iterdir()):
            if f.is_file() and f.suffix == ".md":
                # Read first non-empty, non-meta line as description
                try:
                    for line in f.read_text().split("\n")[:10]:
                        line = line.strip()
                        if line and not line.startswith("#") and not line.startswith("---"):
                            entries.append(f"• {f.stem}: {line[:100]}")
                            break
                    else:
                        entries.append(f"• {f.stem}")
                except Exception:
                    entries.append(f"• {f.stem}")
            elif f.is_dir() and (f / "SKILL.md").exists():
                entries.append(f"• {f.name}/")
        return "\n".join(entries[:20]) if entries else ""
    except Exception:
        return ""


# ── Tool Definitions (minimal set for mobile) ───────────────
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
            "description": "Fetch a URL and extract readable text content. Use this to read web pages, articles, documentation. Supports HTML parsing and text extraction.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "URL to fetch and extract content from"},
                    "max_chars": {"type": "integer", "description": "Max characters to return", "default": 8000},
                },
                "required": ["url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "skill_list",
            "description": "List installed skills (saved procedures/workflows). Skills are reusable instruction files stored on the device.",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "skill_view",
            "description": "Read a skill's content by name. Returns the SKILL.md content.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Skill name (filename without .md)"},
                },
                "required": ["name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "skill_create",
            "description": "Create or update a skill. Save reusable procedures for future use.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Skill name (lowercase, hyphens)"},
                    "content": {"type": "string", "description": "Full SKILL.md content with instructions"},
                },
                "required": ["name", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "memory",
            "description": "Manage persistent memory that survives across sessions. Save user preferences, environment facts, tool quirks. Use 'add' for new entries, 'replace' to update existing, 'remove' to delete.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["add", "replace", "remove"], "description": "Action: add, replace, remove"},
                    "content": {"type": "string", "description": "Entry content (for add/replace)"},
                    "old_text": {"type": "string", "description": "Short substring identifying entry to replace/remove"},
                },
                "required": ["action"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "session_search",
            "description": "Search past conversations for context. Use when user references something from a previous chat.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search keywords (OR for broad search)"},
                    "limit": {"type": "integer", "description": "Max results", "default": 3},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "skill_manage",
            "description": "Manage skills: create, patch, edit, delete. Use 'patch' to fix issues in existing skills you discover during use.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["create", "patch", "edit", "delete"], "description": "Management action"},
                    "name": {"type": "string", "description": "Skill name"},
                    "content": {"type": "string", "description": "Full SKILL.md (for create/edit)"},
                    "old_string": {"type": "string", "description": "Text to find (for patch)"},
                    "new_string": {"type": "string", "description": "Replacement text (for patch)"},
                },
                "required": ["action", "name"],
            },
        },
    },
]


# ── Tool Execution ───────────────────────────────────────────
def execute_tool(name: str, arguments: dict) -> str:
    """Execute a tool call and return the result as a string."""
    try:
        if name == "terminal":
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

        elif name == "read_file":
            path = arguments.get("path", "")
            limit = arguments.get("limit", 200)
            p = Path(path)
            if not p.exists():
                return f"Error: File not found: {path}"
            lines = p.read_text().splitlines()[:limit]
            return "\n".join(f"{i+1}|{line}" for i, line in enumerate(lines))

        elif name == "write_file":
            path = arguments.get("path", "")
            content = arguments.get("content", "")
            p = Path(path)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content)
            return f"Written {len(content)} chars to {path}"

        elif name == "web_search":
            query = arguments.get("query", "")
            # Simple curl-based search (DuckDuckGo lite)
            try:
                import urllib.parse
                encoded = urllib.parse.quote(query)
                result = subprocess.run(
                    ["curl", "-sL", "-A", "Mozilla/5.0", f"https://lite.duckduckgo.com/lite/?q={encoded}"],
                    capture_output=True, text=True, timeout=15,
                )
                # Extract text between <td> tags (DDG lite format)
                import re
                snippets = re.findall(r'<td[^>]*class="result-snippet"[^>]*>(.*?)</td>', result.stdout, re.DOTALL)
                clean = [re.sub(r'<[^>]+>', '', s).strip() for s in snippets[:5]]
                return "\n".join(f"• {s}" for s in clean if s) or "No results found."
            except Exception as e:
                return f"Search error: {e}"

        elif name == "web_scrape":
            url = arguments.get("url", "")
            max_chars = arguments.get("max_chars", 8000)
            if not url:
                return "Error: No URL provided"
            try:
                import urllib.parse
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

                # Try lxml for better parsing, fall back to regex
                try:
                    from lxml import html as lxml_html
                    tree = lxml_html.fromstring(html)
                    # Remove script/style
                    for tag in tree.xpath('//script|//style|//nav|//footer|//header'):
                        tag.getparent().remove(tag)
                    text = tree.text_content()
                except ImportError:
                    # Basic regex cleaning
                    import re
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

        elif name == "skill_list":
            skills_dir = Path(HOME) / ".hermes" / "skills"
            if not skills_dir.exists():
                return "No skills directory found. Create skills with skill_create."
            skills = []
            for f in sorted(skills_dir.iterdir()):
                if f.is_file() and f.suffix == ".md":
                    # Read first line for description
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

        elif name == "skill_view":
            skill_name = arguments.get("name", "")
            if not skill_name:
                return "Error: No skill name provided"
            skills_dir = Path(HOME) / ".hermes" / "skills"
            # Try direct file first
            for candidate in [
                skills_dir / f"{skill_name}.md",
                skills_dir / skill_name / "SKILL.md",
            ]:
                if candidate.exists():
                    content = candidate.read_text()
                    if len(content) > 8000:
                        content = content[:8000] + "\n... (truncated)"
                    return content
            return f"Skill '{skill_name}' not found. Use skill_list to see available skills."

        elif name == "skill_create":
            skill_name = arguments.get("name", "")
            content = arguments.get("content", "")
            if not skill_name or not content:
                return "Error: Both name and content are required"
            # Sanitize name
            import re
            safe_name = re.sub(r'[^a-zA-Z0-9_-]', '-', skill_name).strip('-')
            if not safe_name:
                return "Error: Invalid skill name"
            skills_dir = Path(HOME) / ".hermes" / "skills"
            skills_dir.mkdir(parents=True, exist_ok=True)
            skill_file = skills_dir / f"{safe_name}.md"
            skill_file.write_text(content)
            return f"Skill '{safe_name}' saved to {skill_file}"

        elif name == "memory":
            return execute_memory(arguments)

        elif name == "session_search":
            return execute_session_search(arguments)

        elif name == "skill_manage":
            return execute_skill_manage(arguments)

        else:
            return f"Unknown tool: {name}"

    except subprocess.TimeoutExpired:
        return "Error: Command timed out"
    except Exception as e:
        return f"Error: {str(e)}"


# ── Memory System ──────────────────────────────────────────
MEMORY_FILE = Path(HOME) / ".hermes" / "memory.md" if HOME else None

def execute_memory(arguments: dict) -> str:
    """Manage persistent memory stored in ~/.hermes/memory.md"""
    if not MEMORY_FILE:
        return "Error: HOME not set"

    MEMORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    action = arguments.get("action", "")

    if action == "add":
        content = arguments.get("content", "").strip()
        if not content:
            return "Error: No content to add"
        # Append to memory file
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
        # Remove the line containing old_text
        lines = existing.split("\n")
        new_lines = [l for l in lines if old_text not in l]
        MEMORY_FILE.write_text("\n".join(new_lines))
        return f"Memory removed: '{old_text[:50]}'"

    else:
        return f"Error: Unknown memory action '{action}'"


# ── Session History ────────────────────────────────────────
SESSIONS_DIR = Path(HOME) / ".hermes" / "sessions" if HOME else None

def save_session_turn(user_msg: str, assistant_msg: str):
    """Save a conversation turn to session history for future search."""
    if not SESSIONS_DIR:
        return
    try:
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
        from datetime import datetime
        today = datetime.now().strftime("%Y-%m-%d")
        session_file = SESSIONS_DIR / f"{today}.jsonl"
        entry = json.dumps({
            "ts": datetime.now().isoformat(),
            "user": user_msg[:500],
            "assistant": assistant_msg[:500],
        })
        with open(session_file, "a") as f:
            f.write(entry + "\n")
    except Exception:
        pass


def execute_session_search(arguments: dict) -> str:
    """Search past conversation sessions."""
    if not SESSIONS_DIR or not SESSIONS_DIR.exists():
        return "No session history found."

    query = arguments.get("query", "").lower()
    limit = arguments.get("limit", 3)
    if not query:
        return "Error: No search query provided"

    # Search through session files (newest first)
    results = []
    import re
    keywords = [k.strip() for k in query.split(" OR ")] if " OR " in query else [query]

    for f in sorted(SESSIONS_DIR.glob("*.jsonl"), reverse=True):
        if len(results) >= limit * 3:
            break
        try:
            for line in f.read_text().strip().split("\n"):
                if not line:
                    continue
                entry = json.loads(line)
                text = (entry.get("user", "") + " " + entry.get("assistant", "")).lower()
                if any(kw in text for kw in keywords):
                    results.append({
                        "date": f.stem,
                        "ts": entry.get("ts", "")[:16],
                        "user": entry.get("user", "")[:100],
                        "assistant": entry.get("assistant", "")[:100],
                    })
        except Exception:
            continue

    if not results:
        return f"No conversations found matching '{query}'"

    output = [f"Found {len(results)} matching conversations:"]
    for r in results[:limit]:
        output.append(f"\n[{r['ts']}]")
        output.append(f"  User: {r['user']}")
        output.append(f"  Assistant: {r['assistant']}")

    return "\n".join(output)


# ── Skill Management ───────────────────────────────────────
def execute_skill_manage(arguments: dict) -> str:
    """Advanced skill management: create, patch, edit, delete."""
    action = arguments.get("action", "")
    name = arguments.get("name", "")
    if not name:
        return "Error: Skill name required"

    skills_dir = Path(HOME) / ".hermes" / "skills" if HOME else None
    if not skills_dir:
        return "Error: HOME not set"

    skills_dir.mkdir(parents=True, exist_ok=True)

    # Find skill file (try .md first, then directory/SKILL.md)
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
            import shutil
            shutil.rmtree(skill_dir_file.parent)
            deleted = True
        return f"Skill '{name}' deleted ✓" if deleted else f"Error: Skill '{name}' not found"

    else:
        return f"Error: Unknown action '{action}'"


# ── Chat Logic ───────────────────────────────────────────────
def chat_completion(messages: list, stream: bool = False):
    """Run a chat completion with tool calling loop."""
    client = get_llm_client()
    if not client:
        return {"error": "No LLM client configured. Set NOUS_API_KEY or OPENAI_API_KEY."}

    try:
        response = client.chat.completions.create(
            model=MODEL,
            messages=messages,
            tools=TOOLS,
            max_tokens=4096,
            stream=stream,
        )
        return response
    except Exception as e:
        return {"error": str(e)}


def run_agent_loop(user_message: str, history: list = None) -> dict:
    """Full agent loop: send message, handle tool calls, return final response."""
    client = get_llm_client()
    if not client:
        return {"role": "assistant", "content": "⚠️ No API key configured. Set NOUS_API_KEY in Termux."}

    messages = [{"role": "system", "content": get_system_prompt()}]
    if history:
        messages.extend(history[-20:])  # Keep last 20 messages for context
    messages.append({"role": "user", "content": user_message})

    tool_calls_log = []
    max_iterations = 10

    for iteration in range(max_iterations):
        try:
            response = client.chat.completions.create(
                model=MODEL,
                messages=messages,
                tools=TOOLS,
                max_tokens=4096,
            )
        except Exception as e:
            return {"role": "assistant", "content": f"⚠️ API error: {e}"}

        choice = response.choices[0]

        if choice.finish_reason == "stop":
            return {
                "role": "assistant",
                "content": choice.message.content or "",
                "tool_calls": tool_calls_log,
            }

        if choice.message.tool_calls:
            # Add assistant message with tool calls
            messages.append({
                "role": "assistant",
                "content": choice.message.content,
                "tool_calls": [
                    {
                        "id": tc.id,
                        "type": "function",
                        "function": {
                            "name": tc.function.name,
                            "arguments": tc.function.arguments,
                        },
                    }
                    for tc in choice.message.tool_calls
                ],
            })

            # Execute each tool call
            for tc in choice.message.tool_calls:
                try:
                    args = json.loads(tc.function.arguments)
                except json.JSONDecodeError:
                    args = {}

                result = execute_tool(tc.function.name, args)
                tool_calls_log.append({
                    "name": tc.function.name,
                    "arguments": args,
                    "result": result[:500],
                })

                messages.append({
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": result,
                })
        else:
            # No tool calls but not stop — shouldn't happen, but handle gracefully
            return {
                "role": "assistant",
                "content": choice.message.content or "",
                "tool_calls": tool_calls_log,
            }

    return {
        "role": "assistant",
        "content": "⚠️ Max iterations reached.",
        "tool_calls": tool_calls_log,
    }


# ── Endpoints ────────────────────────────────────────────────
@app.get("/api/health")
async def health():
    """Health check endpoint."""
    return {
        "status": "ok",
        "timestamp": datetime.now().isoformat(),
        "model": get_active_model(),
        "mode": "local" if os.environ.get("LOCAL_LLM_URL") else "cloud",
        "has_api_key": bool(
            os.environ.get("LOCAL_LLM_URL")
            or os.environ.get("NOUS_API_KEY")
            or os.environ.get("OPENAI_API_KEY")
        ),
    }


@app.post("/api/chat")
async def chat(body: dict):
    """Non-streaming chat endpoint."""
    message = body.get("message", "")
    history = body.get("history", [])

    if not message:
        raise HTTPException(400, "Missing 'message' field")

    result = run_agent_loop(message, history)
    # Save to session history for future search
    save_session_turn(message, result.get("content", ""))
    return result


@app.websocket("/ws/chat")
async def ws_chat(websocket: WebSocket):
    """WebSocket endpoint for streaming chat."""
    await websocket.accept()
    logger.info("WebSocket connected")

    client = get_llm_client()
    if not client:
        await websocket.send_json({"type": "error", "content": "No API key configured"})
        await websocket.close()
        return

    history = [{"role": "system", "content": get_system_prompt()}]

    try:
        while True:
            data = await websocket.receive_text()
            msg = json.loads(data)

            if msg.get("type") == "chat":
                user_content = msg.get("message", "")
                if not user_content:
                    continue

                # Add user message
                client_history = msg.get("history", [])
                messages = [{"role": "system", "content": get_system_prompt()}]
                messages.extend(client_history[-20:])
                messages.append({"role": "user", "content": user_content})

                # Agent loop with streaming
                max_iterations = 10
                for iteration in range(max_iterations):
                    try:
                        stream = client.chat.completions.create(
                            model=MODEL,
                            messages=messages,
                            tools=TOOLS,
                            max_tokens=4096,
                            stream=True,
                        )

                        full_content = ""
                        tool_calls_acc = {}

                        for chunk in stream:
                            delta = chunk.choices[0].delta if chunk.choices else None
                            if not delta:
                                continue

                            # Stream text content
                            if delta.content:
                                full_content += delta.content
                                await websocket.send_json({
                                    "type": "assistant",
                                    "content": delta.content,
                                    "streaming": True,
                                })

                            # Accumulate tool calls
                            if delta.tool_calls:
                                for tc in delta.tool_calls:
                                    idx = tc.index
                                    if idx not in tool_calls_acc:
                                        tool_calls_acc[idx] = {
                                            "id": tc.id or "",
                                            "name": "",
                                            "arguments": "",
                                        }
                                    if tc.function:
                                        if tc.function.name:
                                            tool_calls_acc[idx]["name"] = tc.function.name
                                        if tc.function.arguments:
                                            tool_calls_acc[idx]["arguments"] += tc.function.arguments

                        # Check if we have tool calls to execute
                        if tool_calls_acc:
                            # Build assistant message with ALL tool calls first
                            assistant_msg = {
                                "role": "assistant",
                                "content": full_content,
                                "tool_calls": [],
                            }

                            for idx, tc_data in tool_calls_acc.items():
                                await websocket.send_json({
                                    "type": "tool_call",
                                    "tool_name": tc_data["name"],
                                    "content": f"Running {tc_data['name']}...",
                                    "status": "running",
                                })

                                try:
                                    args = json.loads(tc_data["arguments"])
                                except json.JSONDecodeError:
                                    args = {}

                                result = execute_tool(tc_data["name"], args)
                                tc_id = tc_data["id"] or f"call_{idx}"

                                assistant_msg["tool_calls"].append({
                                    "id": tc_id,
                                    "type": "function",
                                    "function": {
                                        "name": tc_data["name"],
                                        "arguments": tc_data["arguments"],
                                    },
                                })

                                # Add tool result message
                                messages.append({
                                    "role": "tool",
                                    "tool_call_id": tc_id,
                                    "content": result,
                                })

                                # Send tool result
                                await websocket.send_json({
                                    "type": "tool_result",
                                    "tool_name": tc_data["name"],
                                    "content": result[:500],
                                    "status": "completed",
                                })

                            # Add the assistant message ONCE after all tool calls
                            # Insert before tool results so message order is correct:
                            # assistant(with tool_calls) -> tool results
                            messages.insert(len(messages) - len(tool_calls_acc), assistant_msg)

                            # Continue the loop for the model's response after tool results
                            continue

                        # No tool calls — send final response
                        if full_content:
                            # Save to session history
                            save_session_turn(user_content, full_content)
                            await websocket.send_json({
                                "type": "assistant",
                                "content": "",
                                "streaming": False,
                            })

                        break  # Done

                    except Exception as e:
                        await websocket.send_json({
                            "type": "error",
                            "content": f"API error: {str(e)}",
                        })
                        break

    except WebSocketDisconnect:
        logger.info("WebSocket disconnected")
    except Exception as e:
        logger.error(f"WebSocket error: {e}", exc_info=True)


@app.post("/api/bootstrap/check")
async def check_bootstrap():
    """Check if environment is set up."""
    checks = {
        "python": sys.version,
        "prefix_exists": os.path.isdir(PREFIX),
        "home_exists": os.path.isdir(HOME),
        "has_api_key": bool(
            os.environ.get("LOCAL_LLM_URL")
            or os.environ.get("NOUS_API_KEY")
            or os.environ.get("OPENAI_API_KEY")
        ),
        "fastapi": HAS_FASTAPI,
        "openai": HAS_OPENAI,
        "mode": "local" if os.environ.get("LOCAL_LLM_URL") else "cloud",
        "active_model": get_active_model(),
    }
    return checks


@app.get("/api/local/discover")
async def discover_local_models():
    """Auto-discover local LLM servers (PocketPal, Ollama, LM Studio)."""
    servers = []
    endpoints = [
        {"name": "PocketPal",  "url": "http://127.0.0.1:8080/v1"},
        {"name": "Ollama",     "url": "http://127.0.0.1:11434/v1"},
        {"name": "LM Studio",  "url": "http://127.0.0.1:1234/v1"},
        {"name": "jan",        "url": "http://127.0.0.1:1337/v1"},
    ]
    import urllib.request
    for ep in endpoints:
        try:
            req = urllib.request.Request(
                f"{ep['url']}/models",
                headers={"Authorization": "Bearer not-needed"},
            )
            resp = urllib.request.urlopen(req, timeout=2)
            if resp.status == 200:
                data = json.loads(resp.read())
                models = [m.get("id", "?") for m in data.get("data", [])]
                servers.append({
                    "name": ep["name"],
                    "url": ep["url"],
                    "available": True,
                    "models": models,
                })
        except Exception:
            pass
    return {"servers": servers}


@app.post("/api/local/configure")
async def configure_local(body: dict):
    """Configure local LLM mode."""
    url = body.get("url", "")
    model = body.get("model", "local")
    key = body.get("api_key", "not-needed")

    if not url:
        # Disable local mode
        os.environ.pop("LOCAL_LLM_URL", None)
        os.environ.pop("LOCAL_LLM_MODEL", None)
        os.environ.pop("LOCAL_LLM_KEY", None)
        return {"status": "ok", "mode": "cloud", "model": MODEL}

    # Enable local mode
    os.environ["LOCAL_LLM_URL"] = url
    os.environ["LOCAL_LLM_MODEL"] = model
    os.environ["LOCAL_LLM_KEY"] = key

    # Save to .env file for persistence
    env_path = Path(HOME) / ".env"
    env_lines = []
    if env_path.exists():
        env_lines = env_path.read_text().splitlines()

    # Remove old local entries
    env_lines = [l for l in env_lines if not l.startswith(("LOCAL_LLM_", "# Hermes Bridge"))]

    env_lines.extend([
        "# Hermes Bridge API Configuration",
        f"LOCAL_LLM_URL={url}",
        f"LOCAL_LLM_MODEL={model}",
        f"LOCAL_LLM_KEY={key}",
    ])
    env_path.write_text("\n".join(env_lines) + "\n")

    return {
        "status": "ok",
        "mode": "local",
        "url": url,
        "model": model,
    }


# ── Main ─────────────────────────────────────────────────────
def main():
    if not HAS_FASTAPI:
        print("ERROR: Install dependencies first:")
        print("  pip install fastapi uvicorn websockets openai")
        sys.exit(1)

    logger.info(f"Starting Hermes Bridge on {HOST}:{PORT}")
    logger.info(f"Active model: {get_active_model()}")
    if os.environ.get("LOCAL_LLM_URL"):
        logger.info(f"Local mode: {os.environ['LOCAL_LLM_URL']}")
    else:
        logger.info("Cloud mode (Nous/OpenAI API)")
    logger.info(f"Prefix: {PREFIX}")
    logger.info(f"Home: {HOME}")

    uvicorn.run(app, host=HOST, port=PORT, log_level="info")


if __name__ == "__main__":
    main()
