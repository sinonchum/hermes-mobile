# Hermes Mobile 📱

> Porting [Hermes Agent](https://github.com/nicholasgasior/nicholasgasior.github.io.git) to Android — an AI assistant that auto-remembers, auto-creates Skills, and runs anywhere.

[中文文档](README_zh.md)

```
┌─────────────────────────────────────────────────────┐
│  🧠  Auto Memory   │  Cross-session persistent notes │
│  📚  Auto Skills   │  Save reusable workflows         │
│  🔍  Chat Search   │  Keyword search past chats       │
│  🔧  Tool Calling  │  Terminal, file, web, search     │
│  📱  Local LLM     │  PocketPal / Ollama / LM Studio  │
│  ☁️  Cloud LLM     │  Nous API / OpenAI compatible    │
└─────────────────────────────────────────────────────┘
```

## Test Device

| Item | Value |
|------|-------|
| **Phone** | Xiaomi 12 Pro (2201122C, codename: zeus) |
| **Brand** | Xiaomi |
| **Android** | 15 (API 35) |
| **Build ID** | AQ3A.250226.002 (LineageOS) |
| **CPU Arch** | arm64-v8a |
| **RAM** | 11 GB |
| **Test Date** | 2026-04-16 |

## Architecture

```
┌──────────────────────────────────────────────┐
│              Android App (Flutter)           │
│  ┌─────────┐  ┌──────────┐  ┌────────────┐  │
│  │Chat UI  │  │Skills    │  │ Model      │  │
│  │         │  │Dashboard │  │ Selector   │  │
│  └────┬────┘  └────┬─────┘  └─────┬──────┘  │
│  ┌────┴────────────┴──────────────┴──────┐   │
│  │       MethodChannel Bridge           │   │
│  └────────────────┬─────────────────────┘   │
│  ┌────────────────┴─────────────────────┐   │
│  │  Kotlin Native Layer                 │   │
│  │  HermesBridgeService (Foreground)    │   │
│  │  TermuxBootstrap                     │   │
│  └─────────────────┼───────────────────┘   │
└────────────────────┼───────────────────────┘
┌────────────────────┼───────────────────────┐
│  Termux Environment (Linux on Android)    │
│  ┌─────────────────┴──────────────────┐    │
│  │  bridge_server.py (FastAPI)        │    │
│  │  Agent Loop: msg→LLM→tool→result   │    │
│  │  12 tools: terminal, file, web,    │    │
│  │  memory, skills, session_search    │    │
│  └────────────────────────────────────┘    │
│        ┌────────────┼────────────┐         │
│        ▼            ▼            ▼         │
│   ☁️ Cloud API   📱 Local LLM   🔧 Shell  │
└────────────────────────────────────────────┘
```

## Features Implemented ✅

### Core Agent System
- [x] **Agent Loop** — Full tool-calling cycle (msg → LLM → tool → result → LLM → response)
- [x] **Streaming WebSocket** — Real-time token-by-token output
- [x] **HTTP Fallback** — Non-streaming POST backup channel
- [x] **Dynamic System Prompt** — Injects model name, Memory, and Skills context

### Tool System (12 tools)
- [x] `terminal` — Execute shell commands on device
- [x] `read_file` — Read device files
- [x] `write_file` — Write device files
- [x] `web_search` — DuckDuckGo search
- [x] `web_scrape` — Web page scraping + text extraction (lxml/regex fallback)
- [x] `memory` — Persistent memory (add/replace/remove)
- [x] `skill_list` — List installed Skills
- [x] `skill_view` — View Skill content
- [x] `skill_create` — Create/update Skill
- [x] `skill_manage` — Advanced Skill management (create/patch/edit/delete)
- [x] `session_search` — Keyword search through conversation history
- [x] `todo` — Task list management

### Auto Memory & Auto Skill System
- [x] **Auto Memory** — Agent automatically saves user preferences and corrections
- [x] **Auto Skill Creation** — Agent proposes saving workflows after complex tasks (5+ tool calls)
- [x] **Auto Skill Patching** — Agent fixes broken Skills on discovery
- [x] **Memory Injection** — `~/.hermes/memory.md` loaded into every system prompt
- [x] **Skill Injection** — Installed Skill list appears in system prompt
- [x] **Session Persistence** — Conversations auto-saved to `~/.hermes/sessions/YYYY-MM-DD.jsonl`

### Model Support
- [x] **Cloud Models** — Nous API (Hermes-3, Mimo, etc.) + any OpenAI-compatible API
- [x] **Local Models** — PocketPal, Ollama, LM Studio, jan (auto-discovery)
- [x] **Model Switching** — Search, select, switch in Flutter UI
- [x] **Mode Indicator** — Status bar shows ☁️ Cloud / 📱 Local

### Flutter UI
- [x] **Chat Screen** — Streaming, tool call visualization, message bubbles
- [x] **Model Selector** — Cloud model search + local model auto-discovery
- [x] **Skills Dashboard** — Three tabs (Skills / Memory / Status)
- [x] **Status Bar** — Connection state, model name, local/cloud mode
- [x] **OAuth Login** — Nous Portal authentication
- [x] **Dark/Light Theme** — Follows system

### Android Native Layer
- [x] **Foreground Service** — HermesBridgeService keeps agent alive
- [x] **WakeLock** — Prevents system from killing agent
- [x] **Termux Bootstrap** — Auto-downloads Termux environment (~29MB) on first launch
- [x] **Dependency Auto-Install** — Python + fastapi + uvicorn + openai + lxml
- [x] **Env Var Management** — SharedPreferences → System.setProperty → .env file

### Server (bridge_server.py)
- [x] FastAPI + Uvicorn WebSocket server
- [x] 6 API endpoints
- [x] Local model auto-discovery (`/api/local/discover`)
- [x] Local model configuration (`/api/local/configure`)

## Not Yet Tested ⏳

| Feature | Status | Notes |
|---------|--------|-------|
| **Local LLM (PocketPal)** | ⚠️ Incomplete | Current PocketPal doesn't expose OpenAI API; test Ollama/Termux instead |
| **Long-term background** | ⏳ Untested | Foreground Service + WakeLock needs extended run test |
| **Termux Bootstrap first install** | ⏳ Untested | Full bootstrap flow on fresh install |
| **Multi-turn context** | ⏳ Untested | 20-message context window management |
| **Auto Skill trigger** | ⏳ Untested | Proposal flow after 5+ tool calls |
| **Network switching (WiFi ↔ 4G)** | ⏳ Untested | WebSocket reconnection mechanism |
| **Low memory scenarios** | ⏳ Untested | Performance on devices with <6GB RAM |

## Development Workflow

### Automated Build-Deploy-Test

```
Code change → flutter build apk --debug → adb uninstall → adb install → adb am start
    │                                                              │
    └──────────── Auto-executed on every change ──────────────────┘
```

```bash
# One-command build & deploy (run from Hermes)
flutter build apk --debug && \
adb uninstall com.hermes.mobile && \
adb install build/app/outputs/flutter-apk/app-debug.apk && \
adb shell am start -n com.hermes.mobile/.MainActivity
```

### Dev Environment

| Tool | Version |
|------|---------|
| Flutter | 3.x (darwin-x64) |
| Android SDK | 35 |
| Python (bridge) | 3.11+ (Termux) |
| Kotlin | JVM 17 |
| Gradle | 8.14 |

### Project Structure

```
hermes_mobile/
├── lib/
│   ├── main.dart                          # Entry + config check
│   ├── config/app_config.dart             # Constants
│   ├── models/message.dart                # Message model
│   ├── screens/
│   │   ├── chat_screen.dart               # Main chat
│   │   ├── model_select_screen.dart       # Model picker (cloud+local)
│   │   ├── nous_login_screen.dart         # Nous OAuth
│   │   ├── setup_screen.dart              # First-time setup
│   │   └── skills_dashboard_screen.dart   # Skills & Memory dashboard
│   ├── services/
│   │   ├── api_client.dart                # WebSocket/HTTP client
│   │   └── chat_provider.dart             # Chat state + Agent Loop
│   └── widgets/
│       ├── message_bubble.dart            # Message bubble
│       └── status_bar.dart                # Status bar
├── android/
│   └── app/src/main/
│       ├── kotlin/com/hermes/mobile/
│       │   ├── MainActivity.kt            # Flutter host Activity
│       │   ├── bridge/HermesBridgeService.kt  # Foreground Service
│       │   └── termux/TermuxBootstrap.kt  # Termux bootstrap
│       └── assets/
│           └── bridge_server.py           # Core agent server (deployed to phone)
├── api_server.py                          # Alt: Full Hermes Agent wrapper
├── pubspec.yaml
├── README.md                              # English (this file)
└── README_zh.md                           # Chinese
```

## Quick Start

### Prerequisites
- Android phone (arm64, Android 10+)
- USB debugging enabled
- Nous API Key (cloud mode) or PocketPal/Ollama (local mode)

### Install

```bash
# 1. Clone
git clone https://github.com/sinonchum/hermes-mobile.git
cd hermes-mobile

# 2. Install Flutter deps
flutter pub get

# 3. Build & deploy (USB connected)
flutter build apk --debug
adb install build/app/outputs/flutter-apk/app-debug.apk

# 4. Launch
adb shell am start -n com.hermes.mobile/.MainActivity
```

### First Launch Flow
1. App checks API Key → redirects to login
2. Nous OAuth login (gets API Key)
3. Select model (cloud/local)
4. Enter chat → start chatting

### Skills & Memory

Tap menu **⋮ → 🧠 Skills & Memory**:
- **Skills** tab: View/delete installed Skills
- **Memory** tab: View persistent memory
- **Status** tab: Bridge status, model mode, storage info

## License

MIT
