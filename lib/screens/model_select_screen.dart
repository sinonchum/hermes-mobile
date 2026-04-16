import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Model selection screen — search + select from API model list.
class ModelSelectScreen extends StatefulWidget {
  final VoidCallback onContinue;

  const ModelSelectScreen({super.key, required this.onContinue});

  @override
  State<ModelSelectScreen> createState() => _ModelSelectScreenState();
}

class _ModelSelectScreenState extends State<ModelSelectScreen> {
  static const _configChannel = MethodChannel('com.hermes.mobile/config');
  static const _bridgeChannel = MethodChannel('com.hermes.mobile/bridge');
  static const _inferenceUrl = 'https://inference-api.nousresearch.com/v1';

  List<String> _models = [];
  List<String> _filteredModels = [];
  String? _selected;
  bool _loading = true;
  String? _error;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchModels();
    _searchController.addListener(_filterModels);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterModels() {
    final query = _searchController.text.toLowerCase().trim();
    setState(() {
      _filteredModels = query.isEmpty
          ? _models
          : _models.where((m) => m.toLowerCase().contains(query)).toList();
      if (_selected != null && !_filteredModels.contains(_selected)) {
        _selected = _filteredModels.isNotEmpty ? _filteredModels.first : null;
      }
    });
  }

  Future<void> _fetchModels() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    List<String> models = [];

    // ── Try local model discovery first ──
    try {
      final localResult = await _bridgeChannel.invokeMethod('httpGet', {
        'url': 'http://127.0.0.1:18923/api/local/discover',
      });
      if (localResult != null) {
        final localData = jsonDecode(localResult as String);
        final servers = localData['servers'] as List? ?? [];
        for (final server in servers) {
          final name = server['name'] as String? ?? 'Unknown';
          final serverModels = server['models'] as List? ?? [];
          for (final m in serverModels) {
            models.add('📱 $m ($name)');
          }
        }
      }
    } catch (_) {
      // Bridge not running or no local servers — that's fine
    }

    // ── Fetch cloud models ──
    try {
      final apiKey = await _configChannel.invokeMethod('getApiKey', {'key': 'nous_api_key'});
      if (apiKey != null && apiKey.toString().isNotEmpty) {
        final result = await _bridgeChannel.invokeMethod('httpGet', {
          'url': '$_inferenceUrl/models',
          'headers': 'Authorization: Bearer $apiKey'
        });

        final data = jsonDecode(result as String);
        if (data is Map && data.containsKey('data')) {
          for (final m in data['data']) {
            final id = m['id'] as String?;
            if (id != null && !id.contains('embed') && !id.contains('moderation')) {
              models.add(id);
            }
          }
        }
      }
    } catch (e) {
      if (models.isEmpty) {
        // No local servers, no cloud key — show fallback
        models.addAll([
          'gpt-4o', 'gpt-4o-mini', 'gpt-4-turbo',
          'nousresearch/hermes-3-llama-3.1-405b',
          'NousResearch/Hermes-3-Llama-3.1-70B',
        ]);
        _error = 'Could not fetch models: $e';
      }
    }

    models.sort((a, b) {
      // Local models first
      if (a.startsWith('📱') && !b.startsWith('📱')) return -1;
      if (!a.startsWith('📱') && b.startsWith('📱')) return 1;
      final ap = _priority(a), bp = _priority(b);
      if (ap != bp) return ap.compareTo(bp);
      return a.compareTo(b);
    });

    if (mounted) {
      setState(() {
        _models = models;
        _filteredModels = models;
        _selected = models.isNotEmpty ? models.first : null;
        _loading = false;
      });
    }
  }

  int _priority(String id) {
    final l = id.toLowerCase();
    if (l.contains('gpt-4o')) return 0;
    if (l.contains('gpt-4')) return 1;
    if (l.contains('hermes')) return 3;
    if (l.contains('mimo')) return 4;
    if (l.contains('llama')) return 5;
    if (l.contains('claude')) return 6;
    if (l.contains('mistral')) return 7;
    return 99;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Model'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _fetchModels,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search models (e.g. mimo, gpt, hermes)...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => _searchController.clear(),
                          )
                        : null,
                    isDense: true,
                  ),
                ),
              ),

              // Count + error
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                child: Row(
                  children: [
                    Text(
                      '${_filteredModels.length} model${_filteredModels.length == 1 ? '' : 's'}',
                      style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                    ),
                    if (_error != null) ...[
                      const Spacer(),
                      Text(_error!, style: TextStyle(fontSize: 11, color: Colors.orange[300])),
                    ],
                  ],
                ),
              ),

              // Model list
              Expanded(
                child: _filteredModels.isEmpty
                    ? Center(
                        child: Text('No models match "${_searchController.text}"',
                            style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5))),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: _filteredModels.length,
                        itemBuilder: (context, i) {
                          final id = _filteredModels[i];
                          final selected = id == _selected;
                          return ListTile(
                            onTap: () => setState(() => _selected = id),
                            selected: selected,
                            selectedTileColor: theme.colorScheme.primaryContainer.withOpacity(0.2),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: BorderSide(
                                color: selected ? theme.colorScheme.primary : Colors.transparent,
                                width: selected ? 2 : 0,
                              ),
                            ),
                            leading: Icon(
                              _icon(id),
                              color: selected ? theme.colorScheme.primary : Colors.grey,
                            ),
                            title: Text(
                              _name(id),
                              style: TextStyle(
                                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                fontSize: 14,
                              ),
                            ),
                            subtitle: Text(id, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                            trailing: selected
                                ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
                                : null,
                            dense: true,
                          );
                        },
                      ),
              ),

              // Continue
              Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _selected != null
                        ? () async {
                            final sel = _selected!;
                            if (sel.startsWith('📱')) {
                              // Local model — extract model name and server
                              // Format: "📱 model-name (ServerName)"
                              final match = RegExp(r'^📱 (.+?) \((.+)\)$').firstMatch(sel);
                              if (match != null) {
                                final modelName = match.group(1)!;
                                final serverName = match.group(2)!;
                                final url = _localServerUrl(serverName);
                                await _configChannel.invokeMethod('setApiKey', {
                                  'key': 'local_llm_url', 'value': url,
                                });
                                await _configChannel.invokeMethod('setApiKey', {
                                  'key': 'local_llm_model', 'value': modelName,
                                });
                              }
                            } else {
                              // Cloud model
                              await _configChannel.invokeMethod('setApiKey', {
                                'key': 'local_llm_url', 'value': '',
                              });
                              await _configChannel.invokeMethod('setModel', {'model': sel});
                            }
                            if (context.mounted) widget.onContinue();
                          }
                        : null,
                    icon: const Icon(Icons.arrow_forward),
                    label: Text(_selected != null
                        ? _selected!.startsWith('📱')
                            ? 'Continue with local model'
                            : 'Continue with ${_name(_selected!)}'
                        : 'Select a model'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ),
            ]),
    );
  }

  String _name(String id) {
    if (id.startsWith('📱')) {
      final match = RegExp(r'^📱 (.+?) \(').firstMatch(id);
      return match?.group(1) ?? id;
    }
    var n = id.split('/').last.replaceAll('-', ' ').replaceAll('_', ' ');
    return n.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
  }

  String _localServerUrl(String serverName) {
    switch (serverName) {
      case 'PocketPal': return 'http://127.0.0.1:8080/v1';
      case 'Ollama': return 'http://127.0.0.1:11434/v1';
      case 'LM Studio': return 'http://127.0.0.1:1234/v1';
      case 'jan': return 'http://127.0.0.1:1337/v1';
      default: return 'http://127.0.0.1:8080/v1';
    }
  }

  IconData _icon(String id) {
    if (id.startsWith('📱')) return Icons.phone_android;
    final l = id.toLowerCase();
    if (l.contains('gpt')) return Icons.auto_awesome;
    if (l.contains('hermes')) return Icons.auto_awesome;
    if (l.contains('mimo')) return Icons.smart_toy;
    if (l.contains('llama')) return Icons.pets;
    if (l.contains('claude')) return Icons.psychology;
    return Icons.model_training;
  }
}
