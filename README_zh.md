# Hermes Mobile 📱

> 将 [Hermes Agent](https://github.com/nicholasgasior/nicholasgasior.github.io.git) 完美移植到 Android 移动端 — 一个会自动记忆、自动创建 Skill 的 AI 助手。

```
┌─────────────────────────────────────────────────────┐
│  🧠  自动记忆    │  跨会话持久化，记住你的偏好     │
│  📚  自动创建Skill │  复杂任务后自动保存可复用流程    │
│  🔍  会话搜索    │  关键词搜索过去的对话           │
│  🔧  工具调用    │  终端、文件、网页抓取、搜索      │
│  📱  本地模型    │  支持 PocketPal / Ollama / LM Studio │
│  ☁️  云端模型    │  支持 Nous API / OpenAI 兼容     │
└─────────────────────────────────────────────────────┘
```

## 测试设备

| 项目 | 值 |
|------|-----|
| **手机型号** | Xiaomi 12 Pro (2201122C, codename: zeus) |
| **品牌** | Xiaomi |
| **Android 版本** | 15 (API 35) |
| **Build ID** | AQ3A.250226.002 (LineageOS) |
| **CPU 架构** | arm64-v8a |
| **RAM** | 11 GB |
| **测试日期** | 2026-04-16 |

## 架构

```
┌──────────────────────────────────────────────┐
│              Android App (Flutter)           │
│  ┌─────────┐  ┌──────────┐  ┌────────────┐  │
│  │Chat UI  │  │Skills    │  │ Model      │  │
│  │         │  │Dashboard │  │ Selector   │  │
│  └────┬────┘  └────┬─────┘  └─────┬──────┘  │
│       │            │              │          │
│  ┌────┴────────────┴──────────────┴──────┐   │
│  │       MethodChannel Bridge           │   │
│  └────────────────┬─────────────────────┘   │
│                   │                         │
│  ┌────────────────┴─────────────────────┐   │
│  │  Kotlin Native Layer                 │   │
│  │  ┌─────────────────────────────────┐ │   │
│  │  │  HermesBridgeService (FGS)      │ │   │
│  │  │  TermuxBootstrap                │ │   │
│  │  │  SharedPreferences config       │ │   │
│  │  └──────────────┬──────────────────┘ │   │
│  └─────────────────┼───────────────────┘   │
└────────────────────┼───────────────────────┘
                     │
┌────────────────────┼───────────────────────┐
│  Termux Environment (Linux on Android)    │
│  ┌─────────────────┴──────────────────┐    │
│  │  bridge_server.py (FastAPI)        │    │
│  │  ┌───────────────────────────────┐ │    │
│  │  │ Agent Loop:                   │ │    │
│  │  │  msg → LLM → tool_call →     │ │    │
│  │  │  execute → result → LLM →    │ │    │
│  │  │  final_response              │ │    │
│  │  └───────────────────────────────┘ │    │
│  │                                    │    │
│  │  Tools: terminal, read_file,       │    │
│  │  write_file, web_search,           │    │
│  │  web_scrape, memory,               │    │
│  │  skill_list/view/create/manage,    │    │
│  │  session_search                    │    │
│  └────────────────────────────────────┘    │
│                     │                       │
│        ┌────────────┼────────────┐          │
│        ▼            ▼            ▼          │
│   ☁️ Cloud API   📱 PocketPal   🔧 Shell   │
│   (Nous/OpenAI)  (Local LLM)   (Android)   │
└────────────────────────────────────────────┘
```

## 已实现功能 ✅

### 核心 Agent 系统
- [x] **Agent Loop** — 完整的 tool-calling 循环 (msg → LLM → tool → result → LLM → response)
- [x] **Streaming WebSocket** — 实时流式响应，逐 token 输出
- [x] **HTTP fallback** — 非流式 HTTP POST 备用通道
- [x] **动态系统 Prompt** — 注入当前模型名、Memory、Skills 上下文

### 工具系统 (12 个工具)
- [x] `terminal` — 在设备上执行 Shell 命令
- [x] `read_file` — 读取设备文件
- [x] `write_file` — 写入设备文件
- [x] `web_search` — DuckDuckGo 搜索
- [x] `web_scrape` — 网页抓取 + 文本提取 (支持 lxml/正则回退)
- [x] `memory` — 持久化记忆 (add/replace/remove)
- [x] `skill_list` — 列出已安装的 Skills
- [x] `skill_view` — 查看 Skill 内容
- [x] `skill_create` — 创建/更新 Skill
- [x] `skill_manage` — Skill 高级管理 (create/patch/edit/delete)
- [x] `session_search` — 关键词搜索过去的对话
- [x] `todo` — 任务列表管理

### 自动记忆 & 自动 Skill 系统
- [x] **自动记忆** — 用户纠正或说出偏好时，Agent 自动调用 `memory` 工具保存
- [x] **自动创建 Skill** — 复杂任务 (5+ tool calls) 完成后，Agent 主动提议保存为 Skill
- [x] **自动 Skill 修复** — 发现 Skill 有 bug 时，Agent 自动调用 `skill_manage(patch)`
- [x] **记忆注入** — 每次回复前，system prompt 自动加载 `~/.hermes/memory.md` 内容
- [x] **Skill 注入** — 已安装的 Skill 列表自动出现在 system prompt 中
- [x] **会话持久化** — 每次对话自动保存到 `~/.hermes/sessions/YYYY-MM-DD.jsonl`

### 模型支持
- [x] **云端模型** — Nous API (Hermes-3, Mimo 等) + 任何 OpenAI 兼容 API
- [x] **本地模型** — PocketPal, Ollama, LM Studio, jan (自动发现)
- [x] **模型切换** — Flutter UI 中搜索、选择、切换模型
- [x] **模式指示** — 状态栏显示 ☁️ Cloud / 📱 Local 模式

### Flutter UI
- [x] **Chat 界面** — 流式对话、工具调用可视化、消息气泡
- [x] **Model Selector** — 云端模型搜索 + 本地模型自动发现
- [x] **Skills Dashboard** — 三个标签页 (Skills / Memory / Status)
- [x] **Status Bar** — 实时显示连接状态、模型名、本地/云端模式
- [x] **OAuth 登录** — Nous Portal 认证流程
- [x] **暗色/亮色主题** — 跟随系统

### Android 原生层
- [x] **Foreground Service** — HermesBridgeService 保持后台运行
- [x] **WakeLock** — 防止系统休眠杀死 Agent
- [x] **Termux Bootstrap** — 首次启动自动下载安装 Termux 环境 (~29MB)
- [x] **依赖自动安装** — Python + fastapi + uvicorn + openai + lxml
- [x] **环境变量管理** — SharedPreferences → System.setProperty → .env 文件
- [x] **API Key 管理** — 支持本地/云端模式切换

### 服务端 (bridge_server.py)
- [x] FastAPI + Uvicorn WebSocket 服务
- [x] 6 个 API 端点
- [x] 本地模型自动发现 (`/api/local/discover`)
- [x] 本地模型配置 (`/api/local/configure`)
- [x] 健康检查 (`/api/health`)
- [x] Session 历史自动保存

## 尚未测试 ⏳

| 功能 | 状态 | 说明 |
|------|------|------|
| **本地模型 (PocketPal)** | ⚠️ 未完成 | PocketPal 当前版本未暴露 OpenAI API，需测试 Ollama/Termux 方案 |
| **长时间后台运行** | ⏳ 未测试 | Foreground Service + WakeLock 需要长时间运行测试 |
| **Termux Bootstrap 首次安装** | ⏳ 未测试 | 需要全新安装测试完整的 bootstrap 流程 |
| **多轮对话上下文** | ⏳ 未测试 | 20 条历史消息的上下文窗口管理 |
| **Skills 自动创建触发** | ⏳ 未测试 | 5+ tool calls 后的提议流程 |
| **网络切换 (WiFi ↔ 4G)** | ⏳ 未测试 | WebSocket 重连机制 |
| **低内存场景** | ⏳ 未测试 | 11GB RAM 设备上的表现 |

## 开发流程

### 自动化开发启动测试

```
修改代码 → flutter build apk --debug → adb uninstall → adb install → adb am start
    │                                                              │
    └──────────── 每次修改自动执行上述流程 ──────────────────────────┘
```

```bash
# 一键构建部署 (Hermes 内执行)
flutter build apk --debug && \
adb uninstall com.hermes.mobile && \
adb install build/app/outputs/flutter-apk/app-debug.apk && \
adb shell am start -n com.hermes.mobile/.MainActivity
```

### 开发环境

| 工具 | 版本 |
|------|------|
| Flutter | 3.x (darwin-x64) |
| Android SDK | 35 |
| Python (bridge) | 3.11+ (Termux) |
| Kotlin | JVM 17 |
| Gradle | 8.14 |

### 项目结构

```
hermes_mobile/
├── lib/
│   ├── main.dart                          # App 入口 + 配置检查
│   ├── config/app_config.dart             # 常量配置
│   ├── models/message.dart                # 消息模型
│   ├── screens/
│   │   ├── chat_screen.dart               # 主聊天界面
│   │   ├── model_select_screen.dart       # 模型选择 (云端+本地)
│   │   ├── nous_login_screen.dart         # Nous OAuth 登录
│   │   ├── setup_screen.dart              # 首次设置
│   │   └── skills_dashboard_screen.dart   # Skills & Memory 仪表盘
│   ├── services/
│   │   ├── api_client.dart                # WebSocket/HTTP 客户端
│   │   └── chat_provider.dart             # 聊天状态管理 + Agent Loop
│   └── widgets/
│       ├── message_bubble.dart            # 消息气泡
│       └── status_bar.dart                # 状态栏
├── android/
│   └── app/src/main/
│       ├── kotlin/com/hermes/mobile/
│       │   ├── MainActivity.kt            # Flutter 主 Activity
│       │   ├── bridge/HermesBridgeService.kt  # 前台服务
│       │   └── termux/TermuxBootstrap.kt  # Termux 环境引导
│       └── assets/
│           └── bridge_server.py           # 核心 Agent 服务端 (部署到手机)
├── api_server.py                          # 备用: 完整 Hermes Agent 包装
├── pubspec.yaml
└── README.md
```

## 快速开始

### 前提条件
- Android 手机 (arm64, Android 10+)
- USB 调试已启用
- Nous API Key (云端模式) 或 PocketPal/Ollama (本地模式)

### 安装

```bash
# 1. 克隆项目
git clone https://github.com/yourname/hermes_mobile.git
cd hermes_mobile

# 2. 安装 Flutter 依赖
flutter pub get

# 3. 构建并部署到手机 (USB 连接)
flutter build apk --debug
adb install build/app/outputs/flutter-apk/app-debug.apk

# 4. 启动
adb shell am start -n com.hermes.mobile/.MainActivity
```

### 首次启动流程
1. App 检测 API Key → 跳转登录
2. Nous OAuth 登录 (获取 API Key)
3. 选择模型 (云端/本地)
4. 进入聊天界面 → 开始对话

### Skills & Memory

点击右上角菜单 **⋮ → 🧠 Skills & Memory**：
- **Skills** 标签: 查看/删除已安装的 Skills
- **Memory** 标签: 查看持久化记忆内容
- **Status** 标签: Bridge 状态、模型模式、存储信息

## License

MIT
