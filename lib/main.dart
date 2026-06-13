// lib/main.dart
//
// Bootstrap dell'applicazione: inizializza Firebase, registra il
// servizio notifiche e monta l'albero widget. Il tema vive in
// core/theme.dart per mantenere questo file focalizzato sull'avvio.
// ─────────────────────────────────────────────────────────────

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/theme.dart';
import 'firebase_options.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/profile_gate_screen.dart';
import 'screens/home/requests_screen.dart';
import 'screens/splash_screen.dart';
import 'services/event_session_service.dart';
import 'services/notification_service.dart';

/// Navigator globale: consente la navigazione da service (es. tap su
/// notifica push) senza dipendere da un BuildContext.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// ScaffoldMessenger globale: consente di mostrare SnackBar da
/// qualunque punto dell'app (es. notifiche in foreground).
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

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

  // Listener notifiche push: foreground, tap, token refresh.
  await NotificationService.instance.init(
    messengerKey: scaffoldMessengerKey,
    onOpenRequests: _openRequestsScreen,
  );

  runApp(const ProxiMeetApp());
}

/// Naviga alla schermata richieste in arrivo (chiamata dal tap su
/// una notifica push). Il guard sull'autenticazione è già fatto
/// dentro NotificationService.
void _openRequestsScreen() {
  navigatorKey.currentState?.push(
    MaterialPageRoute<void>(builder: (_) => const RequestsScreen()),
  );
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
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const _AppEntry(),
    );
  }
}

/// Entry point che mostra la splash animata solo al primo avvio,
/// poi usa lo StreamBuilder per navigare in base allo stato auth.
class _AppEntry extends StatefulWidget {
  const _AppEntry();

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  bool _splashDone = false;

  @override
  Widget build(BuildContext context) {
    if (!_splashDone) {
      return StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return SplashScreen(
              destination: const LoginScreen(),
              onComplete: () => setState(() => _splashDone = true),
            );
          }
          final dest = snapshot.hasData
              ? const ProfileGateScreen()
              : const LoginScreen();
          return SplashScreen(
            destination: dest,
            onComplete: () => setState(() => _splashDone = true),
          );
        },
      );
    }

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _SplashLoader();
        }
        if (snapshot.hasData) return const ProfileGateScreen();
        return const LoginScreen();
      },
    );
  }
}

class _SplashLoader extends StatelessWidget {
  const _SplashLoader();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppTheme.bgDeep,
      body: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppTheme.primary,
          ),
        ),
      ),
    );
  }
}
