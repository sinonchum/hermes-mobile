import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/utils/app_error.dart';

void main() {
  group('AppError.friendlyMessage', () {
    test('detects network errors', () {
      expect(
        AppError.friendlyMessage(Exception('SocketException: Failed host lookup')),
        contains('No internet connection'),
      );
    });

    test('detects timeout errors', () {
      expect(
        AppError.friendlyMessage(TimeoutException('Request timed out')),
        contains('timed out'),
      );
    });

    test('detects 401 errors', () {
      expect(
        AppError.friendlyMessage(Exception('HTTP 401 Unauthorized')),
        contains('Authentication failed'),
      );
    });

    test('detects 429 rate limit', () {
      expect(
        AppError.friendlyMessage(Exception('429 Too Many Requests')),
        contains('Rate limited'),
      );
    });

    test('detects server errors', () {
      expect(
        AppError.friendlyMessage(Exception('500 Internal Server Error')),
        contains('Server error'),
      );
    });

    test('returns generic message for unknown errors', () {
      expect(
        AppError.friendlyMessage(Exception('something weird')),
        contains('Something went wrong'),
      );
    });
  });
}
