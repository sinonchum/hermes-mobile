import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Nous Portal OAuth Device Code flow login screen.
class NousLoginScreen extends StatefulWidget {
  final VoidCallback onLoginSuccess;

  const NousLoginScreen({super.key, required this.onLoginSuccess});

  @override
  State<NousLoginScreen> createState() => _NousLoginScreenState();
}

class _NousLoginScreenState extends State<NousLoginScreen>
    with WidgetsBindingObserver {
  static const _configChannel = MethodChannel('com.hermes.mobile/config');
  static const _bridgeChannel = MethodChannel('com.hermes.mobile/bridge');

  static const _portalUrl = 'https://portal.nousresearch.com';
  static const _clientId = 'hermes-cli';
  static const _scope = 'inference:mint_agent_key';

  _LoginState _state = _LoginState.idle;
  String? _userCode;
  String? _verificationUrl;
  String? _deviceCode;
  int _interval = 5;
  String? _errorMessage;
  Timer? _pollTimer;
  int _secondsRemaining = 0;
  String _debugLog = '';

  void _log(String msg) {
    debugPrint('[HermesLogin] $msg');
    setState(() {
      _debugLog += '$msg\n';
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When user comes back from browser, restart polling if needed
    if (state == AppLifecycleState.resumed &&
        _deviceCode != null &&
        _state == _LoginState.waitingAuth) {
      _log('App resumed — checking token...');
      _checkTokenOnce();
    }
  }

  /// Step 1: Request device code via native HTTP
  Future<void> _startLogin() async {
    setState(() {
      _state = _LoginState.requesting;
      _errorMessage = null;
      _debugLog = '';
    });

    _log('Requesting device code...');

    try {
      final result = await _bridgeChannel.invokeMethod('httpPost', {
        'url': '$_portalUrl/api/oauth/device/code',
        'body': 'client_id=$_clientId&scope=$_scope',
      });

      final data = jsonDecode(result as String);
      _log('Device code received ✓');

      _userCode = data['user_code'] as String;
      _verificationUrl = data['verification_uri_complete'] as String;
      _deviceCode = data['device_code'] as String;
      final expiresIn = data['expires_in'] as int;
      _interval = (data['interval'] as int?) ?? 5;

      setState(() {
        _state = _LoginState.waitingAuth;
        _secondsRemaining = expiresIn;
      });

      // Open browser
      _openBrowser(_verificationUrl!);

      // Start countdown
      _startCountdown(expiresIn);

      // Start polling
      _startPolling();
    } catch (e) {
      _log('Error: $e');
      setState(() {
        _state = _LoginState.error;
        _errorMessage = 'Failed to start login: $e';
      });
    }
  }

  void _openBrowser(String url) async {
    try {
      await _bridgeChannel.invokeMethod('openUrl', {'url': url});
    } catch (_) {
      try {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      } catch (e) {
        _log('Browser open failed: $e');
      }
    }
  }

  void _startCountdown(int seconds) {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _state != _LoginState.waitingAuth) {
        timer.cancel();
        return;
      }
      setState(() {
        _secondsRemaining = (_secondsRemaining - 1).clamp(0, seconds);
      });
      if (_secondsRemaining <= 0) timer.cancel();
    });
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      Duration(seconds: _interval.clamp(3, 10)),
      (_) => _checkTokenOnce(),
    );
  }

  /// Single poll attempt
  Future<void> _checkTokenOnce() async {
    if (_deviceCode == null || _state != _LoginState.waitingAuth) return;

    try {
      _log('Polling token...');
      final result = await _bridgeChannel.invokeMethod('httpPost', {
        'url': '$_portalUrl/api/oauth/token',
        'body':
            'grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=$_clientId&device_code=$_deviceCode',
      });

      final raw = result as String;
      final response = jsonDecode(raw);

      // Check if it's a wrapped error response
      if (response is Map && response.containsKey('status_code')) {
        final statusCode = response['status_code'] as int;
        _log('Poll: HTTP $statusCode');

        if (statusCode == 400) {
          final errVal = response['error'];
          final error = errVal is Map
              ? (errVal['error_description'] ?? errVal['error'] ?? '').toString()
              : errVal.toString();
          if (error.contains('authorization_pending')) return;
          if (error.contains('slow_down')) return;
          if (error.contains('expired_token') || error.contains('access_denied')) {
            _pollTimer?.cancel();
            if (mounted) {
              setState(() {
                _state = _LoginState.error;
                _errorMessage = 'Login expired or denied.';
              });
            }
          }
        }
        return;
      }

      // Success: has access_token
      if (response is Map && response.containsKey('access_token')) {
        _pollTimer?.cancel();
        final accessToken = response['access_token'] as String;
        _log('Got access token ✓');
        await _mintAgentKey(accessToken);
      }
    } catch (e) {
      _log('Poll error: $e');
    }
  }

  /// Mint agent key (with retry on 429/DNS errors)
  Future<void> _mintAgentKey(String accessToken) async {
    setState(() => _state = _LoginState.minting);
    _log('Minting agent key...');

    // Wait for network to stabilize after browser redirect
    await Future.delayed(const Duration(seconds: 2));

    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        // Add delay before retry to handle transient DNS issues
        if (attempt > 0) {
          _log('Retry ${attempt + 1}/3 (waiting ${3 * attempt}s)...');
          await Future.delayed(Duration(seconds: 3 * attempt));
        }

        final result = await _bridgeChannel.invokeMethod('httpPost', {
          'url': '$_portalUrl/api/oauth/agent-key',
          'headers': 'Authorization: Bearer $accessToken',
          'body': '{"min_ttl_seconds": 1800}',
          'contentType': 'application/json',
        });

        final raw = result as String;
        
        // Try parsing as wrapped error first
        try {
          final wrapped = jsonDecode(raw);
          if (wrapped is Map && wrapped.containsKey('status_code')) {
            final code = wrapped['status_code'] as int;
            _log('Mint response: $code (attempt ${attempt + 1})');
            if (code == 429) {
              // Rate limited — wait and retry
              await Future.delayed(Duration(seconds: 3 * (attempt + 1)));
              continue;
            }
            throw Exception('HTTP $code');
          }
        } catch (_) {
          // Not a wrapped error — try parsing as direct success JSON
        }

        // Parse as direct success response
        final data = jsonDecode(raw);
        final apiKey = data['api_key'] as String;
        _log('Got agent key ✓');

        // Save credentials
        await _configChannel.invokeMethod('setApiKey', {
          'key': 'nous_api_key',
          'value': apiKey,
        });
        await _configChannel.invokeMethod('setApiKey', {
          'key': 'nous_access_token',
          'value': accessToken,
        });
        // Don't set model here — let user choose in ModelSelectScreen
        _log('Credentials saved ✓');

        if (mounted) {
          setState(() => _state = _LoginState.success);
          await Future.delayed(const Duration(milliseconds: 800));
          if (mounted) widget.onLoginSuccess();
        }
        return; // Done!
      } catch (e) {
        _log('Mint error (attempt ${attempt + 1}): $e');
        if (attempt == 2) {
          if (mounted) {
            setState(() {
              _state = _LoginState.error;
              _errorMessage = 'Failed to get API key after retries: $e';
            });
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_state) {
            _LoginState.idle => _buildIdleState(theme),
            _LoginState.requesting => _buildLoading('Connecting to Nous Portal...'),
            _LoginState.waitingAuth => _buildWaitingState(theme),
            _LoginState.minting => _buildLoading('Securing your API key...'),
            _LoginState.success => _buildSuccessState(theme),
            _LoginState.error => _buildErrorState(theme),
          },
        ),
      ),
    );
  }

  Widget _buildIdleState(ThemeData theme) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(flex: 2),
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.auto_awesome, size: 40, color: theme.colorScheme.primary),
        ),
        const SizedBox(height: 24),
        Text('Welcome to Hermes',
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Sign in with Nous Portal to get started',
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.6))),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _startLogin,
            icon: const Icon(Icons.login),
            label: const Text('Sign in with Nous Portal'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Divider(color: theme.dividerColor.withOpacity(0.3))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('or',
                style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.4))),
          ),
          Expanded(child: Divider(color: theme.dividerColor.withOpacity(0.3))),
        ]),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _showApiKeyDialog(context),
            icon: const Icon(Icons.key),
            label: const Text('Enter API Key Manually'),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
          ),
        ),
        const Spacer(),
      ],
    );
  }

  Widget _buildWaitingState(ThemeData theme) {
    final m = _secondsRemaining ~/ 60;
    final s = _secondsRemaining % 60;

    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 40),
          Text('Complete login in your browser',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 32),
          Text('Enter this code:', style: theme.textTheme.bodyLarge),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.primary.withOpacity(0.3)),
            ),
            child: Text(
              _userCode ?? '...',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
                color: theme.colorScheme.primary,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => _verificationUrl != null ? _openBrowser(_verificationUrl!) : null,
            child: Text(
              _verificationUrl ?? '...',
              style: TextStyle(
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 12),
            Text('Waiting... ($m:${s.toString().padLeft(2, '0')})',
                style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6))),
          ]),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () => _verificationUrl != null ? _openBrowser(_verificationUrl!) : null,
            icon: const Icon(Icons.open_in_browser),
            label: const Text('Open Browser Again'),
          ),
          // Debug log (small, at bottom)
          if (_debugLog.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_debugLog.split('\n').take(5).join('\n'),
                  style: TextStyle(fontSize: 10, color: Colors.grey[600], fontFamily: 'monospace')),
            ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () {
              _pollTimer?.cancel();
              setState(() => _state = _LoginState.idle);
            },
            child: const Text('Cancel'),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildLoading(String message) {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 24),
        Text(message),
      ]),
    );
  }

  Widget _buildSuccessState(ThemeData theme) {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.check_circle, size: 80, color: Colors.green),
        const SizedBox(height: 24),
        Text("You're all set!",
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Widget _buildErrorState(ThemeData theme) {
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
      const SizedBox(height: 24),
      Text('Login Failed',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      Text(_errorMessage ?? 'Unknown error',
          style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6)),
          textAlign: TextAlign.center),
      // Show debug log
      if (_debugLog.isNotEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_debugLog,
                style: const TextStyle(fontSize: 11, color: Colors.greenAccent, fontFamily: 'monospace')),
          ),
        ),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: () => setState(() => _state = _LoginState.idle),
        icon: const Icon(Icons.refresh),
        label: const Text('Try Again'),
      ),
    ]);
  }

  void _showApiKeyDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter API Key'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'sk-...', labelText: 'API Key'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final key = controller.text.trim();
              if (key.isNotEmpty) {
                await _configChannel.invokeMethod('setApiKey', {
                  'key': 'nous_api_key',
                  'value': key,
                });
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) widget.onLoginSuccess();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

enum _LoginState { idle, requesting, waitingAuth, minting, success, error }
