import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
import 'core/constants.dart';
import 'screens/ble_diag_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const ProxiMeetApp());
}

class ProxiMeetApp extends StatelessWidget {
  const ProxiMeetApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(AppConstants.primarySeedColor);

    return MaterialApp(
      title: 'ProxiMeet — DIAG',
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
      home: const BleDiagScreen(),
    );
  }
}