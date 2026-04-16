import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/message.dart';

/// Manages chat state and direct LLM API calls via Android native HTTP.
/// No Termux/bridge needed — calls Nous/OpenAI API directly through platform channel.
class ChatProvider extends ChangeNotifier {
  static const _configChannel = MethodChannel('com.hermes.mobile/config');
  static const _bridgeChannel = MethodChannel('com.hermes.mobile/bridge');

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
      final localUrl = await _configChannel.invokeMethod('getApiKey', {'key': 'local_llm_url'});
      if (localUrl != null && localUrl.toString().isNotEmpty) {
        _localLlmUrl = localUrl.toString();
        _localLlmModel = (await _configChannel.invokeMethod('getApiKey', {'key': 'local_llm_model'}))?.toString();
        _bridgeState = _bridgeState.copyWith(status: AgentStatus.ready, isBootstrapDone: true);
        notifyListeners();
        return;
      }

      // Fall back to cloud API
      final apiKey = await _configChannel.invokeMethod('getApiKey', {'key': 'nous_api_key'});
      final model = await _configChannel.invokeMethod('getModel');
      if (apiKey != null && apiKey.toString().isNotEmpty) {
        _apiKey = apiKey.toString();
        _model = model?.toString() ?? _model;
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
    _apiKey = null; // Clear cloud key when switching to local
    await _configChannel.invokeMethod('setApiKey', {'key': 'local_llm_url', 'value': url});
    if (model != null) {
      await _configChannel.invokeMethod('setApiKey', {'key': 'local_llm_model', 'value': model});
    }
    _bridgeState = _bridgeState.copyWith(status: AgentStatus.ready, isBootstrapDone: true);
    notifyListeners();
  }

  /// Switch to cloud mode
  Future<void> clearLocalModel() async {
    _localLlmUrl = null;
    _localLlmModel = null;
    await _configChannel.invokeMethod('setApiKey', {'key': 'local_llm_url', 'value': ''});
    notifyListeners();
    await initialize(); // Re-check cloud key
  }

  /// Change model at runtime
  void setModel(String model) {
    _model = model;
    _configChannel.invokeMethod('setModel', {'model': model});
    notifyListeners();
  }

  /// Change API key at runtime
  Future<void> setApiKey(String key) async {
    _apiKey = key;
    await _configChannel.invokeMethod('setApiKey', {'key': 'nous_api_key', 'value': key});
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

    // Run agent loop in background
    _runAgentLoop(text.trim());
  }

  /// Agent loop: send message → handle tool calls → final response.
  Future<void> _runAgentLoop(String userContent) async {
    final messages = <Map<String, dynamic>>[
      {"role": "system", "content": _systemPrompt},
      // Include recent history
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

        final finishReason = choice['finish_reason'];
        final message = choice['message'];

        // Check for tool calls
        final toolCalls = message['tool_calls'] as List?;
        if (toolCalls != null && toolCalls.isNotEmpty) {
          // Add assistant message with tool calls
          messages.add({
            "role": "assistant",
            "content": message['content'],
            "tool_calls": toolCalls,
          });

          // Execute each tool call
          for (final tc in toolCalls) {
            final funcName = tc['function']['name'] as String;
            final funcArgs = tc['function']['arguments'] as String;

            // Show tool call in UI
            _addToolMessage(funcName, 'Running...', 'running');
            notifyListeners();

            final args = jsonDecode(funcArgs);
            final toolResult = await _executeTool(funcName, args);

            // Update tool message
            _updateLastToolMessage(funcName, toolResult, 'completed');

            messages.add({
              "role": "tool",
              "tool_call_id": tc['id'],
              "content": toolResult,
            });
          }
          notifyListeners();
          continue; // Loop for model's response after tool results
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

  /// Call LLM API via Android native HTTP (supports cloud + local)
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
          : 'Authorization: Bearer $_apiKey';

      final result = await _bridgeChannel.invokeMethod('httpPost', {
        'url': apiUrl,
        'headers': authHeader,
        'body': body,
        'contentType': 'application/json',
      });

      return jsonDecode(result as String) as Map<String, dynamic>;
    } catch (e) {
      return {'error': 'API call failed: $e'};
    }
  }

  /// Execute tool call on-device via Android native shell
  Future<String> _executeTool(String name, Map<String, dynamic> args) async {
    try {
      if (name == 'terminal') {
        final cmd = args['command'] as String? ?? '';
        final result = await _bridgeChannel.invokeMethod('execShell', {'command': cmd});
        return (result as String?) ?? '(no output)';
      }
      if (name == 'read_file') {
        final path = args['path'] as String? ?? '';
        final result = await _bridgeChannel.invokeMethod('readFile', {'path': path});
        return (result as String?) ?? 'File not found';
      }
      if (name == 'write_file') {
        final path = args['path'] as String? ?? '';
        final content = args['content'] as String? ?? '';
        final result = await _bridgeChannel.invokeMethod('writeFile', {
          'path': path,
          'content': content,
        });
        return (result as String?) ?? 'Written';
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

  @override
  void dispose() {
    super.dispose();
  }
}

/// Extension for takeLast
extension<T> on Iterable<T> {
  Iterable<T> takeLast(int n) {
    if (length <= n) return this;
    skip(length - n);
    return skip(length - n);
  }
}
