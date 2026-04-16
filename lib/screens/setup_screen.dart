import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// First-launch setup screen for API key configuration.
class SetupScreen extends StatefulWidget {
  final VoidCallback onSetupComplete;

  const SetupScreen({super.key, required this.onSetupComplete});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  static const _configChannel = MethodChannel('com.hermes.mobile/config');

  final _apiKeyController = TextEditingController();
  String _selectedProvider = 'nous';
  bool _obscureKey = true;
  bool _saving = false;

  final _models = {
    'nous': [
      'nousresearch/hermes-3-llama-3.1-405b',
      'nousresearch/hermes-2-pro-mistral-7b',
      'NousResearch/Hermes-3-Llama-3.1-70B',
    ],
    'openai': [
      'gpt-4o',
      'gpt-4o-mini',
      'gpt-4-turbo',
    ],
  };

  String _selectedModel = 'nousresearch/hermes-3-llama-3.1-405b';

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _saveAndContinue() async {
    final key = _apiKeyController.text.trim();
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your API key')),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final prefsKey = _selectedProvider == 'nous' ? 'nous_api_key' : 'openai_api_key';
      await _configChannel.invokeMethod('setApiKey', {'key': prefsKey, 'value': key});
      await _configChannel.invokeMethod('setModel', {'model': _selectedModel});

      if (mounted) widget.onSetupComplete();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),

              // Header
              Icon(Icons.auto_awesome, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                'Welcome to Hermes',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Your AI assistant on Android',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 48),

              // Provider selection
              Text('API Provider', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'nous', label: Text('Nous')),
                  ButtonSegment(value: 'openai', label: Text('OpenAI')),
                ],
                selected: {_selectedProvider},
                onSelectionChanged: (selected) {
                  setState(() {
                    _selectedProvider = selected.first;
                    _selectedModel = _models[_selectedProvider]!.first;
                  });
                },
              ),

              const SizedBox(height: 24),

              // API Key input
              Text('API Key', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _apiKeyController,
                obscureText: _obscureKey,
                decoration: InputDecoration(
                  hintText: _selectedProvider == 'nous'
                      ? 'sk-...'
                      : 'sk-...',
                  prefixIcon: const Icon(Icons.key),
                  suffixIcon: IconButton(
                    icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Model selection
              Text('Model', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _selectedModel,
                items: _models[_selectedProvider]!
                    .map((m) => DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(fontSize: 13))))
                    .toList(),
                onChanged: (v) => setState(() => _selectedModel = v!),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.psychology),
                ),
              ),

              const SizedBox(height: 48),

              // Continue button
              FilledButton.icon(
                onPressed: _saving ? null : _saveAndContinue,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.arrow_forward),
                label: Text(_saving ? 'Saving...' : 'Get Started'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),

              const SizedBox(height: 16),

              // Help text
              Text(
                _selectedProvider == 'nous'
                    ? 'Get your API key at api.nousresearch.com'
                    : 'Get your API key at platform.openai.com',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
