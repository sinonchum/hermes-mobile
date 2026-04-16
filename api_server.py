#!/usr/bin/env python3
"""
Hermes Mobile API Server
========================
Lightweight HTTP/WebSocket server that wraps the AIAgent for the mobile app.
Runs inside Termux on Android, listening on localhost:18923.

Endpoints:
  GET  /api/health          — Health check
  POST /api/chat            — Send a message (returns full response)
  WS   /ws/chat             — WebSocket for streaming responses

Usage:
  python api_server.py [--port 18923] [--host 127.0.0.1]
"""

import argparse
import asyncio
import json
import logging
import os
import sys
import traceback
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

# Add hermes-agent to path
HERMES_DIR = Path(__file__).parent
if str(HERMES_DIR) not in sys.path:
    sys.path.insert(0, str(HERMES_DIR))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("hermes-mobile")

# ---------------------------------------------------------------------------
# Lazy imports — hermes-agent modules are heavy, import on first use
# ---------------------------------------------------------------------------

_agent = None
_agent_lock = None


def get_or_create_agent(session_id: str = "mobile"):
    """Get or create a singleton AIAgent instance."""
    global _agent, _agent_lock
    if _agent_lock is None:
        import threading
        _agent_lock = threading.Lock()

    with _agent_lock:
        if _agent is None:
            try:
                from run_agent import AIAgent
                _agent = AIAgent(
                    model="xiaomi/mimo-v2-pro",
                    provider="nous",
                    platform="mobile",
                    session_id=session_id,
                    quiet_mode=True,
                    skip_context_files=True,
                    skip_memory=False,
                    max_iterations=30,
                )
                log.info("AIAgent initialized (model=xiaomi/mimo-v2-pro, provider=nous)")
            except Exception as e:
                log.error(f"Failed to init AIAgent: {e}")
                raise
    return _agent


# ---------------------------------------------------------------------------
# FastAPI Server
# ---------------------------------------------------------------------------

def create_app():
    """Create the FastAPI app."""
    try:
        from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
        from fastapi.middleware.cors import CORSMiddleware
        from pydantic import BaseModel
    except ImportError:
        log.error("fastapi/uvicorn not installed. Run: pip install fastapi uvicorn websockets")
        sys.exit(1)

    app = FastAPI(
        title="Hermes Mobile API",
        version="1.0.0",
        docs_url=None,  # Disable docs in production
        redoc_url=None,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # ── Models ──────────────────────────────────────────────────────────

    class ChatRequest(BaseModel):
        message: str
        history: Optional[List[Dict[str, str]]] = None
        session_id: Optional[str] = None

    class ChatResponse(BaseModel):
        response: str
        session_id: str
        timestamp: str

    # ── Health ──────────────────────────────────────────────────────────

    @app.get("/api/health")
    async def health():
        return {
            "status": "ok",
            "service": "hermes-mobile",
            "version": "1.0.0",
            "timestamp": datetime.utcnow().isoformat(),
        }

    # ── Chat (HTTP POST) ───────────────────────────────────────────────

    @app.post("/api/chat")
    async def chat(req: ChatRequest):
        """Send a message and get a full response."""
        try:
            session_id = req.session_id or "mobile"
            agent = get_or_create_agent(session_id)

            # Build conversation history if provided
            history = None
            if req.history:
                history = [
                    {"role": m["role"], "content": m["content"]}
                    for m in req.history
                ]

            result = agent.run_conversation(
                user_message=req.message,
                conversation_history=history,
            )

            response_text = result.get("final_response", "")

            return ChatResponse(
                response=response_text,
                session_id=session_id,
                timestamp=datetime.utcnow().isoformat(),
            )
        except Exception as e:
            log.error(f"Chat error: {e}\n{traceback.format_exc()}")
            raise HTTPException(status_code=500, detail=str(e))

    # ── Chat (WebSocket streaming) ─────────────────────────────────────

    @app.websocket("/ws/chat")
    async def websocket_chat(ws: WebSocket):
        """WebSocket endpoint for streaming chat responses."""
        await ws.accept()
        log.info("WebSocket connected")

        session_id = "mobile"

        try:
            while True:
                data = await ws.receive_text()
                try:
                    msg = json.loads(data)
                except json.JSONDecodeError:
                    # Plain text message
                    msg = {"type": "chat", "message": data}

                msg_type = msg.get("type", "chat")

                if msg_type == "chat":
                    user_message = msg.get("message", "")
                    if not user_message.strip():
                        continue

                    session_id = msg.get("session_id", session_id)
                    history = msg.get("history")

                    # Send status
                    await ws.send_json({
                        "type": "status",
                        "content": "thinking",
                    })

                    try:
                        agent = get_or_create_agent(session_id)

                        # Set up streaming callback
                        def stream_delta(delta: str):
                            """Called for each token during streaming."""
                            asyncio.get_event_loop().call_soon_threadsafe(
                                lambda: asyncio.ensure_future(
                                    _safe_send(ws, {
                                        "type": "assistant",
                                        "content": delta,
                                        "streaming": True,
                                    })
                                )
                            )

                        # Set up tool callback
                        def tool_start(tool_name: str, args_preview: str):
                            asyncio.get_event_loop().call_soon_threadsafe(
                                lambda: asyncio.ensure_future(
                                    _safe_send(ws, {
                                        "type": "tool_call",
                                        "tool_name": tool_name,
                                        "content": args_preview,
                                        "status": "running",
                                    })
                                )
                            )

                        def tool_complete(tool_name: str, result_preview: str):
                            asyncio.get_event_loop().call_soon_threadsafe(
                                lambda: asyncio.ensure_future(
                                    _safe_send(ws, {
                                        "type": "tool_result",
                                        "tool_name": tool_name,
                                        "content": result_preview,
                                        "status": "completed",
                                    })
                                )
                            )

                        # Run agent in thread pool (it's synchronous)
                        conv_history = None
                        if history:
                            conv_history = [
                                {"role": m["role"], "content": m["content"]}
                                for m in history
                            ]

                        loop = asyncio.get_event_loop()
                        result = await loop.run_in_executor(
                            None,
                            lambda: agent.run_conversation(
                                user_message=user_message,
                                conversation_history=conv_history,
                            ),
                        )

                        # Send final response
                        final = result.get("final_response", "")
                        await ws.send_json({
                            "type": "assistant",
                            "content": final,
                            "streaming": False,
                        })

                        # Send done status
                        await ws.send_json({
                            "type": "status",
                            "content": "done",
                        })

                    except Exception as e:
                        log.error(f"Agent error: {e}\n{traceback.format_exc()}")
                        await ws.send_json({
                            "type": "error",
                            "content": str(e),
                        })

                elif msg_type == "ping":
                    await ws.send_json({"type": "pong"})

                elif msg_type == "reset":
                    _agent = None
                    session_id = msg.get("session_id", "mobile")
                    await ws.send_json({
                        "type": "status",
                        "content": "reset",
                    })

        except WebSocketDisconnect:
            log.info("WebSocket disconnected")
        except Exception as e:
            log.error(f"WebSocket error: {e}")

    return app


async def _safe_send(ws, data: dict):
    """Send JSON to WebSocket, ignoring errors if disconnected."""
    try:
        await ws.send_json(data)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Hermes Mobile API Server")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host")
    parser.add_argument("--port", type=int, default=18923, help="Bind port")
    parser.add_argument("--reload", action="store_true", help="Auto-reload (dev)")
    args = parser.parse_args()

    log.info(f"Starting Hermes Mobile API on {args.host}:{args.port}")

    try:
        import uvicorn
    except ImportError:
        print("Installing uvicorn...")
        os.system(f"{sys.executable} -m pip install uvicorn fastapi websockets pydantic")
        import uvicorn

    app = create_app()

    uvicorn.run(
        app,
        host=args.host,
        port=args.port,
        log_level="info",
        reload=args.reload,
        ws_max_size=16 * 1024 * 1024,  # 16MB max WS message
    )


if __name__ == "__main__":
    main()
