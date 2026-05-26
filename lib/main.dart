import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'services/chat_provider.dart';
import 'services/platform_service.dart';
import 'screens/chat_screen.dart';
import 'screens/nous_login_screen.dart';
import 'screens/model_select_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HermesMobileApp());
}

class HermesMobileApp extends StatefulWidget {
  const HermesMobileApp({super.key});

  @override
  State<HermesMobileApp> createState() => _HermesMobileAppState();
}

class _HermesMobileAppState extends State<HermesMobileApp> {
  bool _hasApiKey = false;
  bool _hasModel = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkConfig();
  }

  Future<void> _checkConfig() async {
    try {
      final hasKey = await PlatformService.hasAnyApiKey();
      final model = await PlatformService.getModel();
      final localUrl = await PlatformService.getApiKey('local_llm_url');
      setState(() {
        _hasApiKey = hasKey || (localUrl != null && localUrl.isNotEmpty);
        _hasModel = (model != null && model.isNotEmpty) ||
                    (localUrl != null && localUrl.isNotEmpty);
        _checking = false;
      });
    } catch (_) {
      setState(() => _checking = false);
    }
  }

  Widget _getHomeScreen() {
    if (!_hasApiKey) {
      return NousLoginScreen(onLoginSuccess: () {
        setState(() {
          _hasApiKey = true;
          _hasModel = false;
        });
      });
    }
    if (!_hasModel) {
      return ModelSelectScreen(onContinue: () {
        setState(() => _hasModel = true);
      });
    }
    return const ChatScreen();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ChatProvider()),
      ],
      child: MaterialApp(
        title: 'Hermes',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        home: _checking
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : _getHomeScreen(),
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFD4A843),
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: brightness,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF121218) : const Color(0xFFFAFAFA),

      appBarTheme: AppBarTheme(
        centerTitle: true,
        backgroundColor: isDark ? const Color(0xFF1A1A24) : Colors.white,
        foregroundColor: isDark ? Colors.white : Colors.black87,
        elevation: 0,
        scrolledUnderElevation: 2,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: isDark ? Colors.white : Colors.black87,
          letterSpacing: 0.5,
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF2A2A3E) : const Color(0xFFF5F5F5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.outline.withOpacity(0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),

      textTheme: GoogleFonts.interTextTheme(
        ThemeData(brightness: brightness).textTheme,
      ),

      chipTheme: ChipThemeData(
        backgroundColor: isDark ? const Color(0xFF2A2A3E) : const Color(0xFFF0F0F0),
        labelStyle: TextStyle(color: isDark ? Colors.white70 : Colors.black87),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),

      dropdownMenuTheme: DropdownMenuThemeData(
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: isDark ? const Color(0xFF2A2A3E) : const Color(0xFFF5F5F5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
    );
  }
}
