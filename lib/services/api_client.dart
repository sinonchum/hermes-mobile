import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import '../models/message.dart';

/// Platform channel for Android native bridge operations.
class PlatformBridge {
  static const _bridgeChannel = MethodChannel('com.hermes.mobile/bridge');
  static const _bootstrapChannel = MethodChannel('com.hermes.mobile/bootstrap');
  static const _logChannel = EventChannel('com.hermes.mobile/logs');

  /// Start the Hermes bridge service.
  static Future<bool> startBridge({int port = 18923}) async {
    final result = await _bridgeChannel.invokeMethod('startBridge', {'port': port});
    return result == true;
  }

  /// Stop the bridge service.
  static Future<bool> stopBridge() async {
    final result = await _bridgeChannel.invokeMethod('stopBridge');
    return result == true;
  }

  /// Check if bridge service is running.
  static Future<bool> isRunning() async {
    final result = await _bridgeChannel.invokeMethod('isRunning');
    return result == true;
  }

  /// Get the bridge port.
  static Future<int> getPort() async {
    final result = await _bridgeChannel.invokeMethod('getPort');
    return result as int? ?? 18923;
  }

  /// Check if Termux environment is bootstrapped.
  static Future<bool> isBootstrapped() async {
    final result = await _bootstrapChannel.invokeMethod('isBootstrapped');
    return result == true;
  }

  /// Run the bootstrap process.
  static Future<bool> bootstrap() async {
    final result = await _bootstrapChannel.invokeMethod('bootstrap');
    return result == true;
  }

  /// Listen to real-time bootstrap/agent logs.
  static Stream<Map<String, dynamic>> get logStream {
    return _logChannel.receiveBroadcastStream().map((event) {
      if (event is Map) {
        return Map<String, dynamic>.from(event);
      }
      return {'message': event.toString(), 'percent': -1};
    });
  }
}

/// WebSocket client that talks to the running Hermes Agent.
class HermesApiClient {
  final String host;
  final int port;

  WebSocketChannel? _wsChannel;
  StreamController<ChatMessage>? _messageController;
  Timer? _reconnectTimer;
  bool _isConnected = false;

  HermesApiClient({this.host = '127.0.0.1', this.port = 18923});

  String get baseUrl => 'http://$host:$port';
  String get wsUrl => 'ws://$host:$port/ws/chat';

  /// Stream of incoming messages (assistant responses, tool calls, etc.)
  Stream<ChatMessage> get messages =>
      _messageController?.stream ?? const Stream.empty();

  bool get isConnected => _isConnected;

  /// Connect to the Hermes WebSocket endpoint.
  Future<void> connect() async {
    _messageController ??= StreamController<ChatMessage>.broadcast();

    try {
      _wsChannel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _isConnected = true;

      _wsChannel!.stream.listen(
        (data) {
          try {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            final msg = _parseServerMessage(json);
            if (msg != null) {
              _messageController?.add(msg);
            }
          } catch (e) {
            // Raw text message
            _messageController?.add(ChatMessage.assistant(data.toString()));
          }
        },
        onError: (error) {
          _isConnected = false;
          _scheduleReconnect();
        },
        onDone: () {
          _isConnected = false;
          _scheduleReconnect();
        },
      );
    } catch (e) {
      _isConnected = false;
      _scheduleReconnect();
    }
  }

  /// Send a chat message to Hermes.
  void sendMessage(String content, {List<ChatMessage>? history}) {
    if (!_isConnected || _wsChannel == null) return;

    final payload = {
      'type': 'chat',
      'message': content,
      if (history != null)
        'history': history
            .map((m) => {'role': m.role, 'content': m.content})
            .toList(),
    };

    _wsChannel!.sink.add(jsonEncode(payload));
  }

  /// Send a message via HTTP POST (fallback if WebSocket unavailable).
  Future<String> sendMessageHttp(String content) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/chat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'message': content}),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['response'] ?? data['content'] ?? response.body;
      }
      return 'Error: ${response.statusCode}';
    } catch (e) {
      return 'Connection error: $e';
    }
  }

  /// Check if the HTTP API is reachable.
  Future<bool> healthCheck() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/api/health'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Parse incoming server message into ChatMessage.
  ChatMessage? _parseServerMessage(Map<String, dynamic> json) {
    final type = json['type'] as String?;

    switch (type) {
      case 'assistant':
        return ChatMessage.assistant(
          json['content'] as String? ?? '',
          isStreaming: json['streaming'] == true,
        );
      case 'tool_call':
        return ChatMessage.tool(
          toolName: json['tool_name'] as String? ?? 'unknown',
          content: json['content'] as String? ?? '',
          status: json['status'] as String? ?? 'running',
        );
      case 'tool_result':
        return ChatMessage.tool(
          toolName: json['tool_name'] as String? ?? 'unknown',
          content: json['content'] as String? ?? '',
          status: 'completed',
        );
      case 'error':
        return ChatMessage.system('⚠️ ${json['content'] ?? 'Unknown error'}');
      case 'status':
        // Don't show status messages as chat bubbles
        return null;
      default:
        if (json.containsKey('content')) {
          return ChatMessage.assistant(json['content'] as String);
        }
        return null;
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      connect();
    });
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _wsChannel?.sink.close();
    _wsChannel = null;
    _isConnected = false;
  }

  void dispose() {
    disconnect();
    _messageController?.close();
    _messageController = null;
  }
}
