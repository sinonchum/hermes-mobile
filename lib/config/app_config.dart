/// App-wide configuration constants.
class AppConfig {
  // Hermes Bridge
  static const int bridgePort = 18923;
  static const String bridgeHost = '127.0.0.1';
  static const Duration healthCheckTimeout = Duration(seconds: 3);
  static const int maxStartupRetries = 30;

  // Termux Bootstrap
  static const String bootstrapFallbackUrl =
      'https://github.com/termux/termux-app/releases/download/v0.119.0-beta.1/bootstrap-aarch64.zip';
  static const String bootstrapX86Url =
      'https://github.com/termux/termux-packages/releases/download/bootstrap-2024.10.30-r1/bootstrap-x86_64.zip';

  // Hermes Agent
  static const String hermesRepoUrl =
      'https://github.com/nicholasgasior/nicholasgasior.github.io.git';

  // UI
  static const int maxChatHistory = 20; // Messages sent to API context
  static const Duration reconnectDelay = Duration(seconds: 3);
  static const Duration scrollAnimationDuration = Duration(milliseconds: 200);

  // Version
  static const String version = '1.0.0';
  static const int buildNumber = 1;
}
