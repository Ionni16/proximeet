import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../models/user_model.dart';
import '../../services/auth_service.dart';
import '../events/event_list_screen.dart';
import 'linkedin_complete_profile_screen.dart';
import 'login_screen.dart';

class ProfileGateScreen extends StatefulWidget {
  const ProfileGateScreen({super.key});

  @override
  State<ProfileGateScreen> createState() => _ProfileGateScreenState();
}

class _ProfileGateScreenState extends State<ProfileGateScreen> {
  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    final firebaseUser = FirebaseAuth.instance.currentUser;

    if (firebaseUser == null) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
      return;
    }

    final uid = firebaseUser.uid;

    // Crea/ripara subito il documento users/{uid}. Serve soprattutto per Apple,
    // perché Apple può non restituire nome/email dopo il primo login.
    await AuthService.instance.ensureCurrentUserProfileShell();

    final profile = await AuthService.instance.getUserProfile(uid);

    if (!mounted) return;

    if (_needsCompletion(profile, firebaseUser)) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => LinkedInCompleteProfileScreen(
            linkedInProfile: _profilePayload(profile, firebaseUser),
          ),
        ),
      );
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const EventListScreen()),
    );
  }

  bool _needsCompletion(UserModel? profile, User firebaseUser) {
    if (profile == null) return true;

    // uid deve essere sempre quello Firebase Auth. Se manca, va sistemato.
    if (profile.uid.trim().isEmpty || profile.uid.trim() != firebaseUser.uid) {
      return true;
    }

    // Dati minimi necessari per usare sessioni/eventi.
    return profile.firstName.trim().isEmpty ||
        profile.lastName.trim().isEmpty ||
        profile.email.trim().isEmpty ||
        profile.company.trim().isEmpty ||
        profile.role.trim().isEmpty;
  }

  Map<String, dynamic> _profilePayload(UserModel? profile, User firebaseUser) {
    final displayName = (firebaseUser.displayName ?? '').trim();
    final parts = displayName.split(RegExp(r'\\s+')).where((e) => e.isNotEmpty).toList();

    return {
      'firstName': profile?.firstName.trim().isNotEmpty == true
          ? profile!.firstName
          : (parts.isNotEmpty ? parts.first : ''),
      'lastName': profile?.lastName.trim().isNotEmpty == true
          ? profile!.lastName
          : (parts.length > 1 ? parts.sublist(1).join(' ') : ''),
      'email': profile?.email.trim().isNotEmpty == true
          ? profile!.email
          : (firebaseUser.email ?? ''),
      'company': profile?.company ?? '',
      'role': profile?.role ?? '',
      'bio': profile?.bio ?? '',
      'phone': profile?.phone ?? '',
      'photoURL': profile?.avatarURL.trim().isNotEmpty == true
          ? profile!.avatarURL
          : (firebaseUser.photoURL ?? ''),
      'loginProvider': firebaseUser.providerData.any((p) => p.providerId == 'apple.com')
          ? 'apple'
          : 'linkedin',
    };
  }

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
