import 'dart:async';
import 'package:flutter/services.dart';

/// Centralized platform channel service.
/// All MethodChannel calls go through here — single source of truth.
class PlatformService {
  static const _configChannel = MethodChannel('com.hermes.mobile/config');
  static const _bridgeChannel = MethodChannel('com.hermes.mobile/bridge');
  static const _bootstrapChannel = MethodChannel('com.hermes.mobile/bootstrap');
  static const _streamChannel = EventChannel('com.hermes.mobile/stream');

  // ── Config (API keys, model) ──

  static Future<String?> getApiKey(String key) async {
    final result = await _configChannel.invokeMethod('getApiKey', {'key': key});
    return result?.toString();
  }

  static Future<void> setApiKey(String key, String value) async {
    await _configChannel.invokeMethod('setApiKey', {'key': key, 'value': value});
  }

  static Future<bool> hasAnyApiKey() async {
    final result = await _configChannel.invokeMethod('hasAnyApiKey');
    return result == true;
  }

  static Future<String?> getModel() async {
    final result = await _configChannel.invokeMethod('getModel');
    return result?.toString();
  }

  static Future<void> setModel(String model) async {
    await _configChannel.invokeMethod('setModel', {'model': model});
  }

  // ── Bridge (HTTP, shell, files) ──

  static Future<String> httpPost(String url, {
    String? headers,
    String? body,
    String? contentType,
  }) async {
    final result = await _bridgeChannel.invokeMethod('httpPost', {
      'url': url,
      if (headers != null) 'headers': headers,
      if (body != null) 'body': body,
      if (contentType != null) 'contentType': contentType,
    });
    return result as String;
  }

  static Future<String> httpGet(String url, {String? headers}) async {
    final result = await _bridgeChannel.invokeMethod('httpGet', {
      'url': url,
      if (headers != null) 'headers': headers,
    });
    return result as String;
  }

  /// Start a streaming SSE POST request.
  /// Returns a stream of data events. Each event is either:
  /// - {'type': 'data', 'data': '<json string>'} — an SSE data chunk
  /// - {'type': 'done'} — stream complete
  static Stream<Map<String, dynamic>> httpPostStream(String url, {
    String? headers,
    String? body,
    String? contentType,
  }) async* {
    // Start the stream on native side
    await _bridgeChannel.invokeMethod('httpPostStream', {
      'url': url,
      if (headers != null) 'headers': headers,
      if (body != null) 'body': body,
      if (contentType != null) 'contentType': contentType,
    });

    // Listen to the EventChannel
    await for (final event in _streamChannel.receiveBroadcastStream()) {
      if (event is Map) {
        final Map<String, dynamic> typedEvent = Map<String, dynamic>.from(event);
        yield typedEvent;
        if (typedEvent['type'] == 'done') break;
      }
    }
  }

  static Future<String> execShell(String command) async {
    final result = await _bridgeChannel.invokeMethod('execShell', {'command': command});
    return (result as String?) ?? '(no output)';
  }

  static Future<String> readFile(String path) async {
    final result = await _bridgeChannel.invokeMethod('readFile', {'path': path});
    return (result as String?) ?? 'File not found';
  }

  static Future<String> writeFile(String path, String content) async {
    final result = await _bridgeChannel.invokeMethod('writeFile', {
      'path': path,
      'content': content,
    });
    return (result as String?) ?? 'Written';
  }

  static Future<void> openUrl(String url) async {
    await _bridgeChannel.invokeMethod('openUrl', {'url': url});
  }

  // ── Bootstrap ──

  static Future<bool> isBootstrapped() async {
    final result = await _bootstrapChannel.invokeMethod('isBootstrapped');
    return result == true;
  }

  static Future<bool> bootstrap() async {
    final result = await _bootstrapChannel.invokeMethod('bootstrap');
    return result == true;
  }
}
