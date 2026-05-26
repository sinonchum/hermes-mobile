"""Agent loop and chat logic for Hermes Bridge."""

import json
from .config import logger
from .llm import get_llm_client, get_system_prompt, MODEL
from .tools import TOOLS, execute_tool


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
        messages.extend(history[-20:])
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
