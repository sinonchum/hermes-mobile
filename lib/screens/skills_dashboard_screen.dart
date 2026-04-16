import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Skills & Memory Dashboard — shows installed skills, memory, and session stats.
class SkillsDashboardScreen extends StatefulWidget {
  const SkillsDashboardScreen({super.key});

  @override
  State<SkillsDashboardScreen> createState() => _SkillsDashboardScreenState();
}

class _SkillsDashboardScreenState extends State<SkillsDashboardScreen>
    with SingleTickerProviderStateMixin {
  static const _bridgeChannel = MethodChannel('com.hermes.mobile/bridge');

  late final TabController _tabController;
  List<_SkillEntry> _skills = [];
  String _memory = '';
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _healthInfo;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadAll();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    await Future.wait([
      _loadHealth(),
      _loadSkills(),
      _loadMemory(),
    ]);

    setState(() => _loading = false);
  }

  Future<void> _loadHealth() async {
    try {
      final result = await _bridgeChannel.invokeMethod('httpGet', {
        'url': 'http://127.0.0.1:18923/api/health',
      });
      if (result != null) {
        _healthInfo = jsonDecode(result as String);
      }
    } catch (_) {
      _healthInfo = null;
    }
  }

  Future<void> _loadSkills() async {
    try {
      // Try bridge API first
      final result = await _bridgeChannel.invokeMethod('httpGet', {
        'url': 'http://127.0.0.1:18923/api/chat',
      });
      // If bridge is running, use it to get skill list
      // Otherwise fall back to reading files directly via terminal
      final termResult = await _bridgeChannel.invokeMethod('execShell', {
        'command': 'ls -la \$HOME/.hermes/skills/ 2>/dev/null || echo "NO_SKILLS_DIR"',
      });

      if (termResult != null && !termResult.toString().contains('NO_SKILLS_DIR')) {
        final lines = termResult.toString().trim().split('\n');
        final entries = <_SkillEntry>[];
        for (final line in lines) {
          if (line.startsWith('total') || line.trim().isEmpty) continue;
          // Parse ls -la output
          final parts = line.split(RegExp(r'\s+'));
          if (parts.length >= 9) {
            final name = parts.sublist(8).join(' ');
            if (name == '.' || name == '..') continue;
            final isDir = line.startsWith('d');
            final size = int.tryParse(parts[4]) ?? 0;

            // Try to read description
            String desc = '';
            try {
              if (isDir) {
                final descResult = await _bridgeChannel.invokeMethod('execShell', {
                  'command': 'head -5 \$HOME/.hermes/skills/$name/SKILL.md 2>/dev/null | grep -v "^---" | grep -v "^#" | head -1',
                });
                desc = descResult?.toString().trim() ?? '';
              } else if (name.endsWith('.md')) {
                final descResult = await _bridgeChannel.invokeMethod('execShell', {
                  'command': 'head -5 \$HOME/.hermes/skills/$name 2>/dev/null | grep -v "^---" | grep -v "^#" | head -1',
                });
                desc = descResult?.toString().trim() ?? '';
              }
            } catch (_) {}

            entries.add(_SkillEntry(
              name: name,
              isDirectory: isDir,
              sizeBytes: size,
              description: desc,
            ));
          }
        }
        _skills = entries;
      }
    } catch (e) {
      _error = 'Could not load skills: $e';
    }
  }

  Future<void> _loadMemory() async {
    try {
      final result = await _bridgeChannel.invokeMethod('execShell', {
        'command': 'cat \$HOME/.hermes/memory.md 2>/dev/null || echo "NO_MEMORY"',
      });
      if (result != null && !result.toString().contains('NO_MEMORY')) {
        _memory = result.toString().trim();
      }
    } catch (_) {}
  }

  Future<void> _viewSkill(String name) async {
    try {
      final result = await _bridgeChannel.invokeMethod('execShell', {
        'command': 'cat \$HOME/.hermes/skills/$name 2>/dev/null || cat \$HOME/.hermes/skills/$name/SKILL.md 2>/dev/null || echo "NOT_FOUND"',
      });
      if (result != null && mounted) {
        _showContentDialog(name, result.toString());
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _deleteSkill(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Skill'),
        content: Text('Delete "$name"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await _bridgeChannel.invokeMethod('execShell', {
        'command': 'rm -rf \$HOME/.hermes/skills/$name',
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted: $name')),
        );
        _loadSkills();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _showContentDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: SelectableText(
            content,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Skills & Memory'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _loadAll,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              icon: const Icon(Icons.extension),
              text: 'Skills (${_skills.length})',
            ),
            const Tab(icon: Icon(Icons.psychology), text: 'Memory'),
            const Tab(icon: Icon(Icons.info_outline), text: 'Status'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildSkillsTab(theme),
                _buildMemoryTab(theme),
                _buildStatusTab(theme),
              ],
            ),
    );
  }

  Widget _buildSkillsTab(ThemeData theme) {
    if (_error != null) {
      return Center(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)));
    }
    if (_skills.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.extension_off, size: 64, color: theme.colorScheme.onSurface.withOpacity(0.3)),
            const SizedBox(height: 16),
            Text(
              'No skills yet',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Hermes will automatically create skills\nafter complex tasks',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.4),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _skills.length,
      itemBuilder: (context, i) {
        final skill = _skills[i];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: Icon(
              skill.isDirectory ? Icons.folder : Icons.description,
              color: skill.isDirectory ? Colors.amber : theme.colorScheme.primary,
            ),
            title: Text(
              skill.name,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: skill.description.isNotEmpty
                ? Text(skill.description, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12))
                : Text('${skill.sizeBytes} bytes', style: const TextStyle(fontSize: 11)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.visibility, size: 20),
                  onPressed: () => _viewSkill(skill.name),
                  tooltip: 'View',
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
                  onPressed: () => _deleteSkill(skill.name),
                  tooltip: 'Delete',
                ),
              ],
            ),
            onTap: () => _viewSkill(skill.name),
          ),
        );
      },
    );
  }

  Widget _buildMemoryTab(ThemeData theme) {
    if (_memory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.memory, size: 64, color: theme.colorScheme.onSurface.withOpacity(0.3)),
            const SizedBox(height: 16),
            Text(
              'Memory is empty',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Hermes will save important facts here\nautomatically as you chat',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.4),
              ),
            ),
          ],
        ),
      );
    }

    final entries = _memory.split('\n').where((l) => l.trim().isNotEmpty).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Icon(Icons.psychology, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('Persistent Memory', style: theme.textTheme.titleMedium),
            const Spacer(),
            Chip(
              label: Text('${entries.length} entries', style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              _memory,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace', height: 1.6),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusTab(ThemeData theme) {
    final health = _healthInfo;
    final isLocal = health?['mode'] == 'local';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _StatusCard(
          title: 'Bridge Server',
          icon: health != null ? Icons.check_circle : Icons.error_outline,
          color: health != null ? Colors.green : Colors.red,
          items: [
            'Status: ${health != null ? "Running ✓" : "Not running ✗"}',
            if (health != null) ...[
              'Model: ${health['model'] ?? 'unknown'}',
              'Mode: ${isLocal ? "📱 Local" : "☁️ Cloud"}',
              'API Key: ${health['has_api_key'] == true ? "Set ✓" : "Missing ✗"}',
            ],
          ],
        ),
        const SizedBox(height: 12),
        _StatusCard(
          title: 'Skills',
          icon: Icons.extension,
          color: Colors.amber,
          items: [
            'Installed: ${_skills.length}',
            'Directory: ~/.hermes/skills/',
          ],
        ),
        const SizedBox(height: 12),
        _StatusCard(
          title: 'Memory',
          icon: Icons.psychology,
          color: Colors.purple,
          items: [
            'Entries: ${_memory.split("\n").where((l) => l.trim().isNotEmpty).length}',
            'Size: ${_memory.length} chars',
            'File: ~/.hermes/memory.md',
          ],
        ),
        const SizedBox(height: 12),
        _StatusCard(
          title: 'Storage',
          icon: Icons.folder,
          color: Colors.blue,
          items: [
            'Skills: ~/.hermes/skills/',
            'Memory: ~/.hermes/memory.md',
            'Sessions: ~/.hermes/sessions/',
          ],
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: _loadAll,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh All'),
        ),
      ],
    );
  }
}

class _SkillEntry {
  final String name;
  final bool isDirectory;
  final int sizeBytes;
  final String description;

  _SkillEntry({
    required this.name,
    required this.isDirectory,
    required this.sizeBytes,
    required this.description,
  });
}

class _StatusCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final List<String> items;

  const _StatusCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const Divider(),
            ...items.map((item) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(item, style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
            )),
          ],
        ),
      ),
    );
  }
}
