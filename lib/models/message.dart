/// Message model for chat conversations.
class ChatMessage {
  final String id;
  final String role; // 'user', 'assistant', 'system', 'tool'
  final String content;
  final DateTime timestamp;
  final String? toolName;
  final String? toolStatus; // 'running', 'completed', 'error'
  final bool isStreaming;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.toolName,
    this.toolStatus,
    this.isStreaming = false,
  }) : timestamp = timestamp ?? DateTime.now();

  ChatMessage copyWith({
    String? content,
    String? toolName,
    String? toolStatus,
    bool? isStreaming,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      timestamp: timestamp,
      toolName: toolName ?? this.toolName,
      toolStatus: toolStatus ?? this.toolStatus,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }

  factory ChatMessage.user(String content) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'user',
      content: content,
    );
  }

  factory ChatMessage.assistant(String content, {bool isStreaming = false}) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'assistant',
      content: content,
      isStreaming: isStreaming,
    );
  }

  factory ChatMessage.tool({
    required String toolName,
    required String content,
    String status = 'running',
  }) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'tool',
      content: content,
      toolName: toolName,
      toolStatus: status,
    );
  }

  factory ChatMessage.system(String content) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'system',
      content: content,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'content': content,
    'timestamp': timestamp.toIso8601String(),
    if (toolName != null) 'tool_name': toolName,
    if (toolStatus != null) 'tool_status': toolStatus,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] ?? '',
      role: json['role'] ?? 'assistant',
      content: json['content'] ?? '',
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'])
          : DateTime.now(),
      toolName: json['tool_name'],
      toolStatus: json['tool_status'],
    );
  }
}

/// Agent status
enum AgentStatus {
  offline,      // Not running
  bootstrapping,// First-time setup
  starting,     // Agent launching
  ready,        // Ready for messages
  thinking,     // Processing a message
  error,        // Error state
}

/// Bridge connection state
class BridgeState {
  final AgentStatus status;
  final String? errorMessage;
  final int port;
  final bool isBootstrapDone;

  const BridgeState({
    this.status = AgentStatus.offline,
    this.errorMessage,
    this.port = 18923,
    this.isBootstrapDone = false,
  });

  BridgeState copyWith({
    AgentStatus? status,
    String? errorMessage,
    int? port,
    bool? isBootstrapDone,
  }) {
    return BridgeState(
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      port: port ?? this.port,
      isBootstrapDone: isBootstrapDone ?? this.isBootstrapDone,
    );
  }
}
