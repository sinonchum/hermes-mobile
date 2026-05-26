"""Session history management for Hermes Bridge."""

import json
import os
from pathlib import Path
from datetime import datetime

SESSIONS_DIR = Path(os.environ.get("HOME", "")) / ".hermes" / "sessions"


def save_session_turn(user_msg: str, assistant_msg: str):
    """Save a conversation turn to session history for future search."""
    try:
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
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

    results = []
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
