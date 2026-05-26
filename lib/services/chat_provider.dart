import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/message.dart';
import 'platform_service.dart';
import 'message_repository.dart';

/// Manages chat state and LLM API calls.
/// Uses PlatformService for all platform channel communication.
/// Persists messages via MessageRepository (SQLite).
class ChatProvider extends ChangeNotifier {
  static const _portalUrl = 'https://portal.nousresearch.com';
  static const _inferenceUrl = 'https://inference-api.nousresearch.com/v1';

  final List<ChatMessage> _messages = [];
  BridgeState _bridgeState = const BridgeState();
  String? _apiKey;
  String _model = 'nousresearch/hermes-3-llama-3.1-405b';
  bool _isProcessing = false;

  // Session management
  String? _currentSessionId;

  // Local LLM settings
  String? _localLlmUrl;
  String? _localLlmModel;
  String? get localLlmUrl => _localLlmUrl;
  String? get localLlmModel => _localLlmModel;
  String get currentModel => _model;
  bool get isLocalMode => _localLlmUrl != null && _localLlmUrl!.isNotEmpty;
  String? get currentSessionId => _currentSessionId;

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
      final localUrl = await PlatformService.getApiKey('local_llm_url');
      if (localUrl != null && localUrl.isNotEmpty) {
        _localLlmUrl = localUrl;
        _localLlmModel = await PlatformService.getApiKey('local_llm_model');
        _bridgeState = _bridgeState.copyWith(status: AgentStatus.ready, isBootstrapDone: true);
        notifyListeners();
        return;
      }

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

  // ── Session Management ──

  Future<void> startNewSession({String? title}) async {
    _currentSessionId = await MessageRepository.createSession(title: title);
    _messages.clear();
    notifyListeners();
  }

  Future<void> loadSession(String sessionId) async {
    _currentSessionId = sessionId;
    _messages.clear();
    _messages.addAll(await MessageRepository.getMessages(sessionId));
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> getSessions() async {
    return MessageRepository.getSessions();
  }

  Future<void> deleteSession(String sessionId) async {
    await MessageRepository.deleteSession(sessionId);
    if (_currentSessionId == sessionId) {
      _currentSessionId = null;
      _messages.clear();
      notifyListeners();
    }
  }

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

  Future<void> clearLocalModel() async {
    _localLlmUrl = null;
    _localLlmModel = null;
    await PlatformService.setApiKey('local_llm_url', '');
    notifyListeners();
    await initialize();
  }

  void setModel(String model) {
    _model = model;
    PlatformService.setModel(model);
    notifyListeners();
  }

  Future<void> setApiKey(String key) async {
    _apiKey = key;
    await PlatformService.setApiKey('nous_api_key', key);
    _bridgeState = _bridgeState.copyWith(status: AgentStatus.ready);
    notifyListeners();
  }

  /// Send a user message and get response (with streaming + tool calling loop).
  void sendMessage(String text) {
    if (text.trim().isEmpty) return;
    if (!isConnected) return;

    if (_currentSessionId == null) {
      startNewSession(title: text.trim().length > 50 ? '${text.trim().substring(0, 50)}...' : text.trim());
    }

    final userMsg = ChatMessage.user(text.trim());
    _messages.add(userMsg);
    _isProcessing = true;
    _bridgeState = _bridgeState.copyWith(status: AgentStatus.thinking);
    notifyListeners();

    MessageRepository.saveMessage(_currentSessionId!, userMsg);

    _runAgentLoop(text.trim());
  }

  /// Agent loop: send message → stream response → handle tool calls → final response.
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
        final result = await _chatCompleteStreaming(messages);

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

  /// Call LLM API with streaming support.
  /// Falls back to non-streaming if streaming fails.
  Future<Map<String, dynamic>> _chatCompleteStreaming(List<Map<String, dynamic>> messages) async {
    final model = isLocalMode ? (_localLlmModel ?? 'local') : _model;
    final apiUrl = isLocalMode
        ? '${_localLlmUrl}/chat/completions'
        : '$_inferenceUrl/chat/completions';

    final body = jsonEncode({
      "model": model,
      "messages": messages,
      "tools": _tools,
      "max_tokens": 4096,
      "stream": true,
    });

    final authHeader = isLocalMode
        ? 'Authorization: Bearer ***        : 'Authorization: Bearer *** ?? ''}';

    try {
      // Add a streaming assistant message
      final streamingMsg = ChatMessage.assistant('', isStreaming: true);
      _messages.add(streamingMsg);
      notifyListeners();

      String accumulatedContent = '';
      Map<String, dynamic>? toolCallData;
      final toolCallBuffers = <int, Map<String, dynamic>>{};

      await for (final event in PlatformService.httpPostStream(
        apiUrl,
        headers: authHeader,
        body: body,
        contentType: 'application/json',
      )) {
        if (event['type'] == 'data') {
          final dataStr = event['data'] as String;
          try {
            final chunk = jsonDecode(dataStr) as Map<String, dynamic>;
            final choices = chunk['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final delta = choices[0]['delta'] as Map<String, dynamic>?;
              if (delta != null) {
                // Handle content delta
                final content = delta['content'] as String?;
                if (content != null) {
                  accumulatedContent += content;
                  // Update the streaming message
                  final idx = _messages.lastIndexWhere((m) => m.isStreaming && m.role == 'assistant');
                  if (idx >= 0) {
                    _messages[idx] = _messages[idx].copyWith(content: accumulatedContent);
                    notifyListeners();
                  }
                }

                // Handle tool call deltas
                final toolCallsDelta = delta['tool_calls'] as List?;
                if (toolCallsDelta != null) {
                  for (final tc in toolCallsDelta) {
                    final index = tc['index'] as int;
                    if (!toolCallBuffers.containsKey(index)) {
                      toolCallBuffers[index] = {
                        'id': tc['id'] as String? ?? '',
                        'function': {'name': '', 'arguments': ''},
                      };
                    }
                    final buffer = toolCallBuffers[index]!;
                    if (tc['id'] != null) buffer['id'] = tc['id'];
                    final func = tc['function'] as Map<String, dynamic>?;
                    if (func != null) {
                      if (func['name'] != null) {
                        (buffer['function'] as Map<String, dynamic>)['name'] = func['name'];
                      }
                      if (func['arguments'] != null) {
                        (buffer['function'] as Map<String, dynamic>)['arguments'] =
                            ((buffer['function'] as Map<String, dynamic>)['arguments'] as String) +
                            (func['arguments'] as String);
                      }
                    }
                  }
                }
              }
            }
          } catch (_) {
            // Ignore parse errors in streaming chunks
          }
        } else if (event['type'] == 'done') {
          break;
        }
      }

      // Finalize the streaming message
      final idx = _messages.lastIndexWhere((m) => m.isStreaming && m.role == 'assistant');
      if (idx >= 0) {
        _messages[idx] = _messages[idx].copyWith(isStreaming: false);
      }

      // If we got tool calls, return them in the expected format
      if (toolCallBuffers.isNotEmpty) {
        final toolCalls = toolCallBuffers.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        return {
          'choices': [
            {
              'message': {
                'content': accumulatedContent,
                'tool_calls': toolCalls.map((e) => {
                  'id': e.value['id'],
                  'function': e.value['function'],
                }).toList(),
              },
            }
          ],
        };
      }

      // Regular content response
      return {
        'choices': [
          {
            'message': {
              'content': accumulatedContent,
            },
          }
        ],
      };
    } catch (e) {
      // Fallback to non-streaming
      debugPrint('Streaming failed, falling back to non-streaming: $e');

      // Remove the failed streaming message
      final idx = _messages.lastIndexWhere((m) => m.isStreaming);
      if (idx >= 0) _messages.removeAt(idx);

      return _chatCompleteNonStreaming(messages, apiUrl, authHeader);
    }
  }

  /// Non-streaming fallback for LLM API call.
  Future<Map<String, dynamic>> _chatCompleteNonStreaming(
    List<Map<String, dynamic>> messages,
    String apiUrl,
    String authHeader,
  ) async {
    final body = jsonEncode({
      "model": isLocalMode ? (_localLlmModel ?? 'local') : _model,
      "messages": messages,
      "tools": _tools,
      "max_tokens": 4096,
    });

    try {
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
    final msg = ChatMessage.assistant(content);
    _messages.add(msg);
    if (_currentSessionId != null) {
      MessageRepository.saveMessage(_currentSessionId!, msg);
    }
    notifyListeners();
  }

  ChatMessage _addToolMessage(String toolName, String content, String status) {
    final msg = ChatMessage.tool(toolName: toolName, content: content, status: status);
    _messages.add(msg);
    if (_currentSessionId != null) {
      MessageRepository.saveMessage(_currentSessionId!, msg);
    }
    return msg;
  }

  void _updateLastToolMessage(String toolName, String content, String status) {
    final idx = _messages.lastIndexWhere(
      (m) => m.role == 'tool' && m.toolName == toolName && m.toolStatus == 'running',
    );
    if (idx >= 0) {
      _messages[idx] = _messages[idx].copyWith(content: content, toolStatus: status);
      if (_currentSessionId != null) {
        MessageRepository.saveMessage(_currentSessionId!, _messages[idx]);
      }
    }
  }

  void clearMessages() {
    _messages.clear();
    if (_currentSessionId != null) {
      MessageRepository.clearSession(_currentSessionId!);
    }
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
