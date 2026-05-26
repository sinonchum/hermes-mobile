import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/message.dart';
import 'platform_service.dart';

/// Manages chat state and LLM API calls.
/// Uses PlatformService for all platform channel communication.
class ChatProvider extends ChangeNotifier {
  static const _portalUrl = 'https://portal.nousresearch.com';
  static const _inferenceUrl = 'https://inference-api.nousresearch.com/v1';

  final List<ChatMessage> _messages = [];
  BridgeState _bridgeState = const BridgeState();
  String? _apiKey;
  String _model = 'nousresearch/hermes-3-llama-3.1-405b';
  bool _isProcessing = false;

  // Local LLM settings
  String? _localLlmUrl;
  String? _localLlmModel;
  String? get localLlmUrl => _localLlmUrl;
  String? get localLlmModel => _localLlmModel;
  String get currentModel => _model;
  bool get isLocalMode => _localLlmUrl != null && _localLlmUrl!.isNotEmpty;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  BridgeState get bridgeState => _bridgeState;
  bool get isConnected => _apiKey != null || isLocalMode;
  bool get isProcessing => _isProcessing;

  /// System prompt for mobile agent
  String get _systemPrompt {
    final modelName = isLocalMode ? (_localLlmModel ?? 'local model') : _model;
    return '''You are Hermes, an AI assistant running on a mobile device (Android).
You are powered by the $modelName model.
You have access to the device's file system and shell through tool calls.
Be concise, helpful, and mobile-friendly in your responses.
When running terminal commands, explain what you're doing briefly.
When asked what model you are, answer that you are running on $modelName.''';
  }

  /// Tool definitions (executed on-device via Android shell)
  static const _tools = [
    {
      "type": "function",
      "function": {
        "name": "terminal",
        "description": "Execute a shell command on the device.",
        "parameters": {
          "type": "object",
          "properties": {
            "command": {"type": "string", "description": "Shell command to execute"},
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
        "description": "Write content to a file.",
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
  ];

  /// Initialize: load API key from saved config.
  Future<void> initialize() async {
    try {
      // Check local LLM first
      final localUrl = await PlatformService.getApiKey('local_llm_url');
      if (localUrl != null && localUrl.isNotEmpty) {
        _localLlmUrl = localUrl;
        _localLlmModel = await PlatformService.getApiKey('local_llm_model');
        _bridgeState = _bridgeState.copyWith(status: AgentStatus.ready, isBootstrapDone: true);
        notifyListeners();
        return;
      }

      // Fall back to cloud API
      final apiKey = await PlatformService.getApiKey('nous_api_key');
      final model = await PlatformService.getModel();
      if (apiKey != null && apiKey.isNotEmpty) {
        _apiKey = apiKey;
        _model = model ?? _model;
        _bridgeState = _bridgeState.copyWith(status: AgentStatus.ready, isBootstrapDone: true);
      } else {
        _bridgeState = _bridgeState.copyWith(status: AgentStatus.offline);
      }
    } catch (_) {
      _bridgeState = _bridgeState.copyWith(status: AgentStatus.offline);
    }
    notifyListeners();
  }

  /// Configure local LLM mode
  Future<void> setLocalModel({required String url, String? model}) async {
    _localLlmUrl = url;
    _localLlmModel = model;
    _apiKey = null;
    await PlatformService.setApiKey('local_llm_url', url);
    if (model != null) {
      await PlatformService.setApiKey('local_llm_model', model);
    }
    _bridgeState = _bridgeState.copyWith(status: AgentStatus.ready, isBootstrapDone: true);
    notifyListeners();
  }

  /// Switch to cloud mode
  Future<void> clearLocalModel() async {
    _localLlmUrl = null;
    _localLlmModel = null;
    await PlatformService.setApiKey('local_llm_url', '');
    notifyListeners();
    await initialize();
  }

  /// Change model at runtime
  void setModel(String model) {
    _model = model;
    PlatformService.setModel(model);
    notifyListeners();
  }

  /// Change API key at runtime
  Future<void> setApiKey(String key) async {
    _apiKey = key;
    await PlatformService.setApiKey('nous_api_key', key);
    _bridgeState = _bridgeState.copyWith(status: AgentStatus.ready);
    notifyListeners();
  }

  /// Send a user message and get response (with tool calling loop).
  void sendMessage(String text) {
    if (text.trim().isEmpty) return;
    if (!isConnected) return;

    final userMsg = ChatMessage.user(text.trim());
    _messages.add(userMsg);
    _isProcessing = true;
    _bridgeState = _bridgeState.copyWith(status: AgentStatus.thinking);
    notifyListeners();

    _runAgentLoop(text.trim());
  }

  /// Agent loop: send message → handle tool calls → final response.
  Future<void> _runAgentLoop(String userContent) async {
    final messages = <Map<String, dynamic>>[
      {"role": "system", "content": _systemPrompt},
      ..._messages.take(_messages.length - 1).takeLast(20).map((m) => {
            "role": m.role == 'tool' ? 'assistant' : m.role,
            "content": m.content,
          }),
      {"role": "user", "content": userContent},
    ];

    const maxIterations = 8;

    for (int iteration = 0; iteration < maxIterations; iteration++) {
      try {
        final result = await _chatComplete(messages);

        if (result.containsKey('error')) {
          _addAssistantMessage('⚠️ ${result['error']}');
          break;
        }

        final choice = result['choices']?[0];
        if (choice == null) {
          _addAssistantMessage('⚠️ Unexpected response format');
          break;
        }

        final message = choice['message'];

        // Check for tool calls
        final toolCalls = message['tool_calls'] as List?;
        if (toolCalls != null && toolCalls.isNotEmpty) {
          messages.add({
            "role": "assistant",
            "content": message['content'],
            "tool_calls": toolCalls,
          });

          for (final tc in toolCalls) {
            final funcName = tc['function']['name'] as String;
            final funcArgs = tc['function']['arguments'] as String;

            _addToolMessage(funcName, 'Running...', 'running');
            notifyListeners();

            final args = jsonDecode(funcArgs);
            final toolResult = await _executeTool(funcName, args);

            _updateLastToolMessage(funcName, toolResult, 'completed');

            messages.add({
              "role": "tool",
              "tool_call_id": tc['id'],
              "content": toolResult,
            });
          }
          notifyListeners();
          continue;
        }

        // Final response
        final content = message['content'] as String? ?? '';
        if (content.isNotEmpty) {
          _addAssistantMessage(content);
        }
        break;
      } catch (e) {
        _addAssistantMessage('⚠️ Error: $e');
        break;
      }
    }

    _isProcessing = false;
    _bridgeState = _bridgeState.copyWith(status: AgentStatus.ready);
    notifyListeners();
  }

  /// Call LLM API via PlatformService
  Future<Map<String, dynamic>> _chatComplete(List<Map<String, dynamic>> messages) async {
    final model = isLocalMode ? (_localLlmModel ?? 'local') : _model;
    final apiUrl = isLocalMode
        ? '${_localLlmUrl}/chat/completions'
        : '$_inferenceUrl/chat/completions';

    final body = jsonEncode({
      "model": model,
      "messages": messages,
      "tools": _tools,
      "max_tokens": 4096,
    });

    try {
      final authHeader = isLocalMode
          ? 'Authorization: Bearer not-needed'
          : 'Authorization: Bearer ${_apiKey ?? ''}';

      final result = await PlatformService.httpPost(
        apiUrl,
        headers: authHeader,
        body: body,
        contentType: 'application/json',
      );

      return jsonDecode(result) as Map<String, dynamic>;
    } catch (e) {
      return {'error': 'API call failed: $e'};
    }
  }

  /// Execute tool call on-device
  Future<String> _executeTool(String name, Map<String, dynamic> args) async {
    try {
      if (name == 'terminal') {
        final cmd = args['command'] as String? ?? '';
        return await PlatformService.execShell(cmd);
      }
      if (name == 'read_file') {
        final path = args['path'] as String? ?? '';
        return await PlatformService.readFile(path);
      }
      if (name == 'write_file') {
        final path = args['path'] as String? ?? '';
        final content = args['content'] as String? ?? '';
        return await PlatformService.writeFile(path, content);
      }
      return 'Unknown tool: $name';
    } catch (e) {
      return 'Tool error: $e';
    }
  }

  void _addAssistantMessage(String content) {
    _messages.add(ChatMessage.assistant(content));
    notifyListeners();
  }

  void _addToolMessage(String toolName, String content, String status) {
    _messages.add(ChatMessage.tool(toolName: toolName, content: content, status: status));
  }

  void _updateLastToolMessage(String toolName, String content, String status) {
    final idx = _messages.lastIndexWhere(
      (m) => m.role == 'tool' && m.toolName == toolName && m.toolStatus == 'running',
    );
    if (idx >= 0) {
      _messages[idx] = _messages[idx].copyWith(content: content, toolStatus: status);
    }
  }

  void clearMessages() {
    _messages.clear();
    notifyListeners();
  }
}

/// Extension for takeLast
extension<T> on Iterable<T> {
  Iterable<T> takeLast(int n) {
    if (length <= n) return this;
    return skip(length - n);
  }
}
