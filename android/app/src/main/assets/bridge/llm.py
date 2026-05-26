"""LLM client and model management."""

import os
from .config import HAS_OPENAI, logger

try:
    from openai import OpenAI
except ImportError:
    pass

MODEL = os.environ.get("HERMES_MODEL", "gpt-4o-mini")


def get_llm_client():
    """Create OpenAI-compatible client. Supports cloud + local (PocketPal/Ollama)."""
    if not HAS_OPENAI:
        return None

    # Local model mode (PocketPal, Ollama, LM Studio, etc.)
    local_base = os.environ.get("LOCAL_LLM_URL")
    if local_base:
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


def get_active_model() -> str:
    """Return the active model identifier."""
    if os.environ.get("LOCAL_LLM_URL"):
        return os.environ.get("LOCAL_LLM_MODEL", "local")
    return MODEL


def load_memory_context() -> str:
    """Load persistent memory from ~/.hermes/memory.md"""
    from pathlib import Path
    try:
        mem_file = Path(os.environ.get("HOME", "")) / ".hermes" / "memory.md"
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
    from pathlib import Path
    try:
        skills_dir = Path(os.environ.get("HOME", "")) / ".hermes" / "skills"
        if not skills_dir.exists():
            return ""
        entries = []
        for f in sorted(skills_dir.iterdir()):
            if f.is_file() and f.suffix == ".md":
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


def get_system_prompt() -> str:
    """Build system prompt with dynamic model name, memory, and skills."""
    active = get_active_model()
    memory_context = load_memory_context()
    skills_context = load_skills_context()

    return f"""You are Hermes, an AI assistant running on a mobile device (Android).
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
