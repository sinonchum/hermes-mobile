import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/message.dart';

/// Callback for message actions (retry, delete, etc.)
typedef MessageActionCallback = void Function(String action, ChatMessage message);

/// Renders a single chat message with role-appropriate styling.
class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final MessageActionCallback? onAction;

  const MessageBubble({super.key, required this.message, this.onAction});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Widget bubble;
    switch (message.role) {
      case 'user':
        bubble = _UserBubble(message: message, isDark: isDark);
        break;
      case 'assistant':
        bubble = _AssistantBubble(message: message, isDark: isDark, theme: theme);
        break;
      case 'tool':
        bubble = _ToolBubble(message: message, isDark: isDark, theme: theme);
        break;
      case 'system':
        bubble = _SystemBubble(message: message, theme: theme);
        break;
      default:
        bubble = const SizedBox.shrink();
    }

    // Wrap with long-press menu for user and assistant messages
    if (message.role == 'user' || message.role == 'assistant') {
      return GestureDetector(
        onLongPress: () => _showContextMenu(context),
        child: bubble,
      );
    }

    return bubble;
  }

  void _showContextMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: message.content));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)),
                );
              },
            ),
            if (message.role == 'assistant') ...[
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Retry'),
                onTap: () {
                  Navigator.pop(ctx);
                  onAction?.call('retry', message);
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                onAction?.call('delete', message);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// User message — aligned right, accent color.
class _UserBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isDark;

  const _UserBubble({required this.message, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 48, bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isDark
              ? Theme.of(context).colorScheme.primary.withOpacity(0.8)
              : Theme.of(context).colorScheme.primary,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(4),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          ),
        ),
        child: Text(
          message.content,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
      ),
    );
  }
}

/// Assistant message — aligned left, with markdown rendering.
class _AssistantBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isDark;
  final ThemeData theme;

  const _AssistantBubble({
    required this.message,
    required this.isDark,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(right: 48, bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2A3E) : const Color(0xFFF0F0F0),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.isStreaming && message.content.isEmpty)
              _TypingIndicator()
            else
              MarkdownBody(
                data: message.content,
                selectable: true,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    color: isDark ? Colors.white : Colors.black87,
                    fontSize: 15,
                    height: 1.5,
                  ),
                  code: TextStyle(
                    backgroundColor: isDark
                        ? const Color(0xFF1E1E2E)
                        : const Color(0xFFF5F5F5),
                    color: isDark ? const Color(0xFFE06C75) : const Color(0xFFC7254E),
                    fontFamily: 'JetBrains Mono, monospace',
                    fontSize: 13,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1E1E2E)
                        : const Color(0xFFF8F8F8),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withOpacity(0.1)
                          : Colors.black.withOpacity(0.1),
                    ),
                  ),
                  codeblockPadding: const EdgeInsets.all(12),
                  blockquote: TextStyle(
                    color: isDark ? Colors.grey[400] : Colors.grey[600],
                    fontStyle: FontStyle.italic,
                  ),
                  h1: TextStyle(
                    color: isDark ? Colors.white : Colors.black87,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  h2: TextStyle(
                    color: isDark ? Colors.white : Colors.black87,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  h3: TextStyle(
                    color: isDark ? Colors.white : Colors.black87,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  listBullet: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
              ),
            if (message.isStreaming) _TypingIndicator(),
          ],
        ),
      ),
    );
  }
}

/// Tool call indicator — shows tool name and status.
class _ToolBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isDark;
  final ThemeData theme;

  const _ToolBubble({
    required this.message,
    required this.isDark,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final isRunning = message.toolStatus == 'running';
    final isError = message.toolStatus == 'error';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.orange.withOpacity(0.1)
            : Colors.orange.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.orange.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          if (isRunning)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.orange,
              ),
            )
          else
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              size: 16,
              color: isError ? Colors.red : Colors.green,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '🔧 ${message.toolName ?? "Tool"}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.orange[300] : Colors.orange[800],
                  ),
                ),
                if (message.content.isNotEmpty && !isRunning)
                  Text(
                    message.content.length > 200
                        ? '${message.content.substring(0, 200)}...'
                        : message.content,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                      fontFamily: 'monospace',
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// System message — centered, subtle.
class _SystemBubble extends StatelessWidget {
  final ChatMessage message;
  final ThemeData theme;

  const _SystemBubble({required this.message, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(
          message.content,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurface.withOpacity(0.5),
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }
}

/// Animated typing indicator (three dots).
class _TypingIndicator extends StatefulWidget {
  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final offset = (_controller.value + i * 0.3) % 1.0;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.grey.withOpacity(0.3 + offset * 0.7),
              ),
            );
          }),
        );
      },
    );
  }
}
