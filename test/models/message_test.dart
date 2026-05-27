import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/models/message.dart';

void main() {
  group('ChatMessage', () {
    test('user factory creates correct message', () {
      final msg = ChatMessage.user('Hello');
      expect(msg.role, 'user');
      expect(msg.content, 'Hello');
      expect(msg.isStreaming, false);
      expect(msg.id.isNotEmpty, true);
    });

    test('assistant factory creates correct message', () {
      final msg = ChatMessage.assistant('Hi there', isStreaming: true);
      expect(msg.role, 'assistant');
      expect(msg.content, 'Hi there');
      expect(msg.isStreaming, true);
    });

    test('tool factory creates correct message', () {
      final msg = ChatMessage.tool(toolName: 'terminal', content: 'ls output', status: 'running');
      expect(msg.role, 'tool');
      expect(msg.toolName, 'terminal');
      expect(msg.toolStatus, 'running');
    });

    test('system factory creates correct message', () {
      final msg = ChatMessage.system('System notice');
      expect(msg.role, 'system');
      expect(msg.content, 'System notice');
    });

    test('copyWith preserves unchanged fields', () {
      final msg = ChatMessage.user('Hello');
      final copy = msg.copyWith(content: 'Updated');
      expect(copy.id, msg.id);
      expect(copy.role, 'user');
      expect(copy.content, 'Updated');
    });

    test('toJson and fromJson round-trip', () {
      final msg = ChatMessage.tool(
        toolName: 'read_file',
        content: 'file content',
        status: 'completed',
      );
      final json = msg.toJson();
      final restored = ChatMessage.fromJson(json);
      expect(restored.id, msg.id);
      expect(restored.role, 'tool');
      expect(restored.content, 'file content');
      expect(restored.toolName, 'read_file');
      expect(restored.toolStatus, 'completed');
    });

    test('fromJson handles missing fields gracefully', () {
      final json = {'id': '123', 'role': 'user'};
      final msg = ChatMessage.fromJson(json);
      expect(msg.id, '123');
      expect(msg.role, 'user');
      expect(msg.content, '');
    });
  });

  group('BridgeState', () {
    test('default state is offline', () {
      const state = BridgeState();
      expect(state.status, AgentStatus.offline);
      expect(state.errorMessage, null);
      expect(state.isBootstrapDone, false);
    });

    test('copyWith preserves unchanged fields', () {
      const state = BridgeState();
      final updated = state.copyWith(status: AgentStatus.ready, isBootstrapDone: true);
      expect(updated.status, AgentStatus.ready);
      expect(updated.isBootstrapDone, true);
      expect(updated.port, 18923);
    });
  });

  group('AgentStatus', () {
    test('has all expected values', () {
      expect(AgentStatus.values.length, 6);
      expect(AgentStatus.values, contains(AgentStatus.offline));
      expect(AgentStatus.values, contains(AgentStatus.ready));
      expect(AgentStatus.values, contains(AgentStatus.thinking));
      expect(AgentStatus.values, contains(AgentStatus.error));
    });
  });
}
