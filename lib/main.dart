import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'firebase_options.dart';
import 'core/constants.dart';
import 'screens/auth/login_screen.dart';
import 'screens/events/event_list_screen.dart';
import 'services/event_session_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
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
    const seedColor = Color(AppConstants.primarySeedColor);

    return MaterialApp(
      title: 'ProxiMeet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasData) return const EventListScreen();
          return const LoginScreen();
        },
      ),
    );
  }
}
