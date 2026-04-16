import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/message.dart';
import '../services/chat_provider.dart';

/// Compact status bar showing agent connection state.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final state = provider.bridgeState;
        final (color, icon, text) = _statusInfo(state, provider);

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            border: Border(
              bottom: BorderSide(color: color.withOpacity(0.3), width: 1),
            ),
          ),
          child: Row(
            children: [
              if (state.status == AgentStatus.thinking ||
                  state.status == AgentStatus.starting ||
                  state.status == AgentStatus.bootstrapping)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              else
                Icon(icon, size: 14, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    color: color,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  (Color, IconData, String) _statusInfo(BridgeState state, ChatProvider provider) {
    switch (state.status) {
      case AgentStatus.offline:
        return (Colors.grey, Icons.cloud_off, 'Disconnected');
      case AgentStatus.bootstrapping:
        return (Colors.orange, Icons.build, 'Setting up environment...');
      case AgentStatus.starting:
        return (Colors.blue, Icons.rocket_launch, 'Starting Hermes...');
      case AgentStatus.ready:
        final model = provider.localLlmModel ?? provider.currentModel;
        final modePrefix = provider.isLocalMode ? '📱' : '☁️';
        return (Colors.green, Icons.check_circle, '$modePrefix Ready — $model');
      case AgentStatus.thinking:
        return (Colors.purple, Icons.psychology, 'Thinking...');
      case AgentStatus.error:
        return (Colors.red, Icons.error, state.errorMessage ?? 'Error');
    }
  }
}
