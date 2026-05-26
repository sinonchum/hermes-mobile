"""Hermes Bridge Server — Entry point.

Runs inside Termux on Android, bridges Flutter UI to LLM + tools.

Endpoints:
  GET  /api/health         — Health check
  POST /api/chat           — Send message, get response (non-streaming)
  WS   /ws/chat            — WebSocket for streaming chat
  POST /api/bootstrap/check — Check environment status
"""

import sys
from .config import HAS_FASTAPI, HOST, PORT, PREFIX, HOME, logger
from .llm import get_active_model


def main():
    if not HAS_FASTAPI:
        print("ERROR: Install dependencies first:")
        print("  pip install fastapi uvicorn websockets openai")
        sys.exit(1)

    import uvicorn
    from .routes import app

    logger.info(f"Starting Hermes Bridge on {HOST}:{PORT}")
    logger.info(f"Active model: {get_active_model()}")
    import os
    if os.environ.get("LOCAL_LLM_URL"):
        logger.info(f"Local mode: {os.environ['LOCAL_LLM_URL']}")
    else:
        logger.info("Cloud mode (Nous/OpenAI API)")
    logger.info(f"Prefix: {PREFIX}")
    logger.info(f"Home: {HOME}")

    uvicorn.run(app, host=HOST, port=PORT, log_level="info")


if __name__ == "__main__":
    main()
