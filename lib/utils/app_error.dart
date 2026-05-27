import 'package:flutter/foundation.dart';

/// Centralized error handling for Hermes Mobile.
/// All errors should go through this to ensure consistent logging.
class AppError {
  /// Log an error with context tag.
  /// In debug mode, prints to console.
  /// In production, could be sent to crash reporting.
  static void log(String tag, String message, [Object? error, StackTrace? stack]) {
    if (kDebugMode) {
      debugPrint('[$tag] $message${error != null ? ': $error' : ''}');
      if (stack != null) {
        debugPrint(stack.toString().split('\n').take(5).join('\n'));
      }
    }
    // TODO: In production, send to crash reporting service
  }

  /// Get user-friendly error message from exception.
  static String friendlyMessage(Object error) {
    final msg = error.toString();

    if (msg.contains('SocketException') || msg.contains('Failed host lookup')) {
      return 'No internet connection. Please check your network.';
    }
    if (msg.contains('TimeoutException') || msg.contains('timeout')) {
      return 'Request timed out. Please try again.';
    }
    if (msg.contains('401') || msg.contains('Unauthorized')) {
      return 'Authentication failed. Please check your API key.';
    }
    if (msg.contains('429') || msg.contains('Too Many Requests')) {
      return 'Rate limited. Please wait a moment and try again.';
    }
    if (msg.contains('500') || msg.contains('502') || msg.contains('503')) {
      return 'Server error. Please try again later.';
    }

    return 'Something went wrong. Please try again.';
  }
}
