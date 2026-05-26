"""FastAPI routes for Hermes Bridge."""

import os
import sys
import json
from pathlib import Path
from datetime import datetime

from .config import HAS_FASTAPI, logger
from .llm import get_active_model, get_llm_client, get_system_prompt, MODEL
from .tools import TOOLS, execute_tool
from .agent import run_agent_loop
from .sessions import save_session_turn

if HAS_FASTAPI:
    from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
    from fastapi.middleware.cors import CORSMiddleware

    app = FastAPI(title="Hermes Bridge", version="1.0.0")
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )
else:
    app = None


# ── Health ──────────────────────────────────────────────────
if app:
    @app.get("/api/health")
    async def health():
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


# ── Chat (non-streaming) ───────────────────────────────────
if app:
    @app.post("/api/chat")
    async def chat(body: dict):
        message = body.get("message", "")
        history = body.get("history", [])
        if not message:
            raise HTTPException(400, "Missing 'message' field")
        result = run_agent_loop(message, history)
        save_session_turn(message, result.get("content", ""))
        return result


# ── WebSocket (streaming) ──────────────────────────────────
if app:
    @app.websocket("/ws/chat")
    async def ws_chat(websocket: WebSocket):
        await websocket.accept()
        logger.info("WebSocket connected")

        client = get_llm_client()
        if not client:
            await websocket.send_json({"type": "error", "content": "No API key configured"})
            await websocket.close()
            return

        try:
            while True:
                data = await websocket.receive_text()
                msg = json.loads(data)

                if msg.get("type") == "chat":
                    user_content = msg.get("message", "")
                    if not user_content:
                        continue

                    client_history = msg.get("history", [])
                    messages = [{"role": "system", "content": get_system_prompt()}]
                    messages.extend(client_history[-20:])
                    messages.append({"role": "user", "content": user_content})

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

                                if delta.content:
                                    full_content += delta.content
                                    await websocket.send_json({
                                        "type": "assistant",
                                        "content": delta.content,
                                        "streaming": True,
                                    })

                                if delta.tool_calls:
                                    for tc in delta.tool_calls:
                                        idx = tc.index
                                        if idx not in tool_calls_acc:
                                            tool_calls_acc[idx] = {"id": tc.id or "", "name": "", "arguments": ""}
                                        if tc.function:
                                            if tc.function.name:
                                                tool_calls_acc[idx]["name"] = tc.function.name
                                            if tc.function.arguments:
                                                tool_calls_acc[idx]["arguments"] += tc.function.arguments

                            if tool_calls_acc:
                                assistant_msg = {"role": "assistant", "content": full_content, "tool_calls": []}

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
                                        "function": {"name": tc_data["name"], "arguments": tc_data["arguments"]},
                                    })

                                    messages.append({"role": "tool", "tool_call_id": tc_id, "content": result})

                                    await websocket.send_json({
                                        "type": "tool_result",
                                        "tool_name": tc_data["name"],
                                        "content": result[:500],
                                        "status": "completed",
                                    })

                                messages.insert(len(messages) - len(tool_calls_acc), assistant_msg)
                                continue

                            if full_content:
                                save_session_turn(user_content, full_content)
                                await websocket.send_json({"type": "assistant", "content": "", "streaming": False})

                            break

                        except Exception as e:
                            await websocket.send_json({"type": "error", "content": f"API error: {str(e)}"})
                            break

        except WebSocketDisconnect:
            logger.info("WebSocket disconnected")
        except Exception as e:
            logger.error(f"WebSocket error: {e}", exc_info=True)


# ── Bootstrap check ────────────────────────────────────────
if app:
    @app.post("/api/bootstrap/check")
    async def check_bootstrap():
        return {
            "python": sys.version,
            "prefix_exists": os.path.isdir(os.environ.get("PREFIX", "")),
            "home_exists": os.path.isdir(os.environ.get("HOME", "")),
            "has_api_key": bool(
                os.environ.get("LOCAL_LLM_URL")
                or os.environ.get("NOUS_API_KEY")
                or os.environ.get("OPENAI_API_KEY")
            ),
            "fastapi": HAS_FASTAPI,
            "mode": "local" if os.environ.get("LOCAL_LLM_URL") else "cloud",
            "active_model": get_active_model(),
        }


# ── Local model discovery ─────────────────────────────────
if app:
    @app.get("/api/local/discover")
    async def discover_local_models():
        servers = []
        endpoints = [
            {"name": "PocketPal", "url": "http://127.0.0.1:8080/v1"},
            {"name": "Ollama", "url": "http://127.0.0.1:11434/v1"},
            {"name": "LM Studio", "url": "http://127.0.0.1:1234/v1"},
            {"name": "jan", "url": "http://127.0.0.1:1337/v1"},
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
                    servers.append({"name": ep["name"], "url": ep["url"], "available": True, "models": models})
            except Exception:
                pass
        return {"servers": servers}


# ── Local model configuration ─────────────────────────────
if app:
    @app.post("/api/local/configure")
    async def configure_local(body: dict):
        url = body.get("url", "")
        model = body.get("model", "local")
        key = body.get("api_key", "not-needed")

        if not url:
            os.environ.pop("LOCAL_LLM_URL", None)
            os.environ.pop("LOCAL_LLM_MODEL", None)
            os.environ.pop("LOCAL_LLM_KEY", None)
            return {"status": "ok", "mode": "cloud", "model": MODEL}

        os.environ["LOCAL_LLM_URL"] = url
        os.environ["LOCAL_LLM_MODEL"] = model
        os.environ["LOCAL_LLM_KEY"] = key

        env_path = Path(os.environ.get("HOME", "")) / ".env"
        env_lines = []
        if env_path.exists():
            env_lines = env_path.read_text().splitlines()

        env_lines = [l for l in env_lines if not l.startswith(("LOCAL_LLM_", "# Hermes Bridge"))]
        env_lines.extend([
            "# Hermes Bridge API Configuration",
            f"LOCAL_LLM_URL={url}",
            f"LOCAL_LLM_MODEL={model}",
            f"LOCAL_LLM_KEY={key}",
        ])
        env_path.write_text("\n".join(env_lines) + "\n")

        return {"status": "ok", "mode": "local", "url": url, "model": model}
