import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/message.dart';
import '../services/chat_provider.dart';
import '../widgets/message_bubble.dart';
import '../widgets/status_bar.dart';
import 'skills_dashboard_screen.dart';

/// Main chat screen — the primary interface for interacting with Hermes.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Initialize provider after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().initialize();
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    context.read<ChatProvider>().sendMessage(text);
    _textController.clear();
    _focusNode.requestFocus();

    // Auto-scroll to bottom
    Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hermes'),
        centerTitle: true,
        actions: [
          Consumer<ChatProvider>(
            builder: (context, provider, _) {
              return IconButton(
                icon: Icon(
                  provider.isConnected ? Icons.cloud_done : Icons.cloud_off,
                  color: provider.isConnected
                      ? Colors.greenAccent
                      : theme.colorScheme.error,
                ),
                tooltip: provider.isConnected ? 'Connected' : 'Disconnected',
                onPressed: () {
                  if (!provider.isConnected) {
                    provider.initialize();
                  }
                },
              );
            },
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'clear':
                  context.read<ChatProvider>().clearMessages();
                  break;
                case 'model':
                  _showModelSheet(context);
                  break;
                case 'api':
                  _showApiSheet(context);
                  break;
                case 'skills':
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const SkillsDashboardScreen(),
                  ));
                  break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'skills', child: Text('🧠 Skills & Memory')),
              const PopupMenuItem(value: 'model', child: Text('🔄 Change Model')),
              const PopupMenuItem(value: 'api', child: Text('🔑 Change API Key')),
              const PopupMenuItem(value: 'clear', child: Text('🗑️ Clear chat')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Connection status bar
          const StatusBar(),

          // Chat messages
          Expanded(
            child: Consumer<ChatProvider>(
              builder: (context, provider, _) {
                if (provider.messages.isEmpty && !provider.isProcessing) {
                  return _EmptyState(onSuggestion: _onSuggestionTap);
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: provider.messages.length,
                  itemBuilder: (context, index) {
                    return MessageBubble(message: provider.messages[index]);
                  },
                );
              },
            ),
          ),

          // Input area
          _InputBar(
            controller: _textController,
            focusNode: _focusNode,
            onSend: _sendMessage,
          ),
        ],
      ),
    );
  }

  void _onSuggestionTap(String text) {
    _textController.text = text;
    _sendMessage();
  }

  /// Bottom sheet to change model
  void _showModelSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text('Change Model', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder(
                future: _fetchModelList(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final models = snapshot.data ?? [];
                  if (models.isEmpty) {
                    return const Center(child: Text('Could not fetch models'));
                  }
                  return ListView.builder(
                    controller: scrollController,
                    itemCount: models.length,
                    itemBuilder: (_, i) => ListTile(
                      title: Text(models[i].split('/').last, style: const TextStyle(fontSize: 14)),
                      subtitle: Text(models[i], style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                      onTap: () {
                        context.read<ChatProvider>().setModel(models[i]);
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Model changed to ${models[i].split('/').last}')),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<List<String>> _fetchModelList() async {
    const platform = MethodChannel('com.hermes.mobile/config');
    const bridge = MethodChannel('com.hermes.mobile/bridge');
    try {
      final apiKey = await platform.invokeMethod('getApiKey', {'key': 'nous_api_key'});
      if (apiKey == null) return [];
      final result = await bridge.invokeMethod('httpGet', {
        'url': 'https://inference-api.nousresearch.com/v1/models',
        'headers': 'Authorization: Bearer $apiKey',
      });
      final data = jsonDecode(result as String);
      final models = <String>[];
      if (data is Map && data.containsKey('data')) {
        for (final m in data['data']) {
          final id = m['id'] as String?;
          if (id != null && !id.contains('embed')) models.add(id);
        }
      }
      return models..sort();
    } catch (_) {
      return ['gpt-4o', 'gpt-4o-mini', 'nousresearch/hermes-3-llama-3.1-405b'];
    }
  }

  /// Bottom sheet to change API key
  void _showApiSheet(BuildContext context) {
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Change API Key', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'sk-...',
                labelText: 'New API Key',
                prefixIcon: Icon(Icons.key),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                final key = controller.text.trim();
                if (key.isNotEmpty) {
                  const platform = MethodChannel('com.hermes.mobile/config');
                  await platform.invokeMethod('setApiKey', {'key': 'nous_api_key', 'value': key});
                  context.read<ChatProvider>().initialize();
                  if (ctx.mounted) Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('API key updated')),
                  );
                }
              },
              icon: const Icon(Icons.save),
              label: const Text('Save'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                // Go back to full re-login
                Navigator.pop(ctx);
              },
              child: const Text('Sign in with Nous Portal instead'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Empty state with quick-start suggestions.
class _EmptyState extends StatelessWidget {
  final ValueChanged<String> onSuggestion;

  const _EmptyState({required this.onSuggestion});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestions = [
      '👋 What can you do?',
      '🔍 Search the web for latest AI news',
      '📝 Help me write an email',
      '💻 Run a Python script',
      '🌐 Check a website for me',
    ];

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 64,
              color: theme.colorScheme.primary.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'Hermes Agent',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Your AI assistant with full tool access',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 32),
            ...suggestions.map((s) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: ActionChip(
                label: Text(s),
                onPressed: () => onSuggestion(s),
              ),
            )),
          ],
        ),
      ),
    );
  }
}

/// Text input bar with send button.
class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8 + 16), // Bottom safe area
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E2E) : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF2A2A3E) : const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  maxLines: 4,
                  minLines: 1,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: 'Message Hermes...',
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    hintStyle: TextStyle(
                      color: theme.colorScheme.onSurface.withOpacity(0.4),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(Icons.send, color: Colors.white, size: 20),
                onPressed: onSend,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
