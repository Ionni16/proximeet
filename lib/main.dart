import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'firebase_options.dart';
import 'screens/auth/login_screen.dart';
import 'screens/events/event_list_screen.dart';
import 'services/event_session_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarBrightness: Brightness.dark,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const ProxiMeetApp());
}

class ProxiMeetApp extends StatefulWidget {
  const ProxiMeetApp({super.key});

  @override
  State<ProxiMeetApp> createState() => _ProxiMeetAppState();
}

class _ProxiMeetAppState extends State<ProxiMeetApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      EventSessionService.instance.leaveEvent();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ProxiMeet',
      debugShowCheckedModeBanner: false,
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: ThemeMode.dark,
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const _SplashLoader();
          }
          if (snapshot.hasData) return const EventListScreen();
          return const LoginScreen();
        },
      ),
    );
  }

  static ThemeData _buildDarkTheme() {
    const primary = Color(0xFF4D8EF7);
    const primaryDark = Color(0xFF1A56DB);
    const bgDeep = Color(0xFF050D1E);
    const bgCard = Color(0xFF0D1B30);
    const bgSurface = Color(0xFF101E35);
    const textPrimary = Color(0xFFE8F0FE);
    const textSecondary = Color(0xFF8BA3C7);

    final cs = ColorScheme(
      brightness: Brightness.dark,
      primary: primary,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFF1A3560),
      onPrimaryContainer: const Color(0xFF90CAF9),
      secondary: const Color(0xFF64B5F6),
      onSecondary: bgDeep,
      secondaryContainer: const Color(0xFF1A3560),
      onSecondaryContainer: const Color(0xFF90CAF9),
      tertiary: const Color(0xFF80DEEA),
      onTertiary: bgDeep,
      tertiaryContainer: const Color(0xFF003B4A),
      onTertiaryContainer: const Color(0xFF80DEEA),
      error: const Color(0xFFEF5350),
      onError: Colors.white,
      errorContainer: const Color(0xFF4A1010),
      onErrorContainer: const Color(0xFFEF9A9A),
      surface: bgCard,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      outline: const Color(0xFF2A3F5F),
      outlineVariant: const Color(0xFF1A2D47),
      shadow: Colors.black,
      scrim: Colors.black87,
      inverseSurface: textPrimary,
      onInverseSurface: bgDeep,
      inversePrimary: primaryDark,
      surfaceContainerHighest: bgSurface,
      surfaceContainerHigh: bgCard,
      surfaceContainer: bgDeep,
      surfaceContainerLow: bgDeep,
      surfaceContainerLowest: bgDeep,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: bgDeep,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
      ),
      cardTheme: CardTheme(
        color: bgCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFF1A2D47), width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: const WidgetStatePropertyAll(primary),
          foregroundColor: const WidgetStatePropertyAll(Colors.white),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.3),
          ),
          elevation: const WidgetStatePropertyAll(0),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(primary),
          side: WidgetStatePropertyAll(
            BorderSide(color: primary.withOpacity(0.4)),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      textButtonTheme: const TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(primary),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgSurface,
        hintStyle: const TextStyle(color: textSecondary),
        labelStyle: const TextStyle(color: textSecondary),
        prefixIconColor: textSecondary,
        suffixIconColor: textSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF1A2D47)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF1A2D47)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFEF5350)),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFEF5350), width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: primary.withOpacity(0.15),
        iconTheme: const WidgetStatePropertyAll(
          IconThemeData(color: textSecondary, size: 24),
        ),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: textSecondary,
            letterSpacing: 0.3,
          ),
        ),
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF1A2D47),
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xFF1A2D47),
        contentTextStyle: TextStyle(color: textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogTheme(
        backgroundColor: bgCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: Color(0xFF1A2D47)),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF0D1B30),
        surfaceTintColor: Colors.transparent,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: textPrimary),
        headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: textPrimary),
        headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: textPrimary),
        titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.1, color: textPrimary),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: textPrimary),
        titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.1, color: textPrimary),
        bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: textPrimary, height: 1.5),
        bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: textPrimary, height: 1.5),
        bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, letterSpacing: 0.1, color: textSecondary, height: 1.4),
        labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: textPrimary),
        labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.5, color: textSecondary),
        labelSmall: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, letterSpacing: 0.8, color: textSecondary),
      ),
    );
  }

  static ThemeData _buildLightTheme() {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF1A56DB),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
    );
  }
}

class _SplashLoader extends StatelessWidget {
  const _SplashLoader();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF050D1E),
      body: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF4D8EF7),
          ),
        ),
      ),
    );
  }
}
