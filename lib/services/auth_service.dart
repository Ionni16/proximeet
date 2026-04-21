import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../core/logger.dart';
import '../models/user_model.dart';

/// Servizio autenticazione e gestione profilo utente.
///
/// Singleton: usa [AuthService.instance].
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<UserCredential> login(String email, String password) async {
    final normalizedEmail = email.trim().toLowerCase();

    return _auth.signInWithEmailAndPassword(
      email: normalizedEmail,
      password: password,
    );
  }

  Future<void> register({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
    required String company,
    required String role,
    String? phone,
    String? linkedin,
    String? github,
    String? twitter,
    String? bio,
  }) async {
    UserCredential? credential;

    final normalizedEmail = email.trim().toLowerCase();
    final normalizedFirstName = firstName.trim();
    final normalizedLastName = lastName.trim();
    final normalizedCompany = company.trim();
    final normalizedRole = role.trim();
    final normalizedPhone = _normalizeOptional(phone);
    final normalizedLinkedin = _normalizeOptional(linkedin);
    final normalizedGithub = _normalizeOptional(github);
    final normalizedTwitter = _normalizeTwitter(twitter);
    final normalizedBio = _normalizeOptional(bio);

    try {
      credential = await _auth.createUserWithEmailAndPassword(
        email: normalizedEmail,
        password: password,
      );

      final firebaseUser = credential.user;
      if (firebaseUser == null) {
        throw Exception('Registrazione non completata');
      }

      final uid = firebaseUser.uid;

      final user = UserModel(
        uid: uid,
        firstName: normalizedFirstName,
        lastName: normalizedLastName,
        email: normalizedEmail,
        company: normalizedCompany,
        role: normalizedRole,
        avatarURL: '',
        linkedin: normalizedLinkedin,
        github: normalizedGithub,
        twitter: normalizedTwitter,
        phone: normalizedPhone,
        bio: normalizedBio,
        createdAt: DateTime.now(),
      );

      await _db.collection('users').doc(uid).set(user.toMap());

      try {
        await firebaseUser.updateDisplayName(user.fullName);
      } catch (e) {
        Log.e('AUTH', 'Errore updateDisplayName post-register', e);
      }
    } catch (e) {
      final createdUid = credential?.user?.uid;

      // Rollback: se Auth è stato creato ma Firestore fallisce,
      // proviamo a non lasciare account mezzi creati.
      if (createdUid != null) {
        try {
          await _db.collection('users').doc(createdUid).delete();
        } catch (_) {}

        try {
          await credential?.user?.delete();
        } catch (_) {}
      }

      rethrow;
    }
  }

  Future<void> logout() async {
    await _auth.signOut();
  }

  Future<UserModel?> getUserProfile(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;

    final data = doc.data();
    if (data == null) return null;

    return UserModel.fromMap(data);
  }

  Future<void> updateAvatar(String uid, String avatarURL) async {
    final normalizedAvatarUrl = avatarURL.trim();

    await _db.collection('users').doc(uid).set({
      'avatarURL': normalizedAvatarUrl,
    }, SetOptions(merge: true));
  }

  Future<void> updateProfile(String uid, Map<String, dynamic> data) async {
    if (data.isEmpty) return;

    final normalized = <String, dynamic>{};

    for (final entry in data.entries) {
      final key = entry.key;
      final value = entry.value;

      if (value is String) {
        if (key == 'email') {
          normalized[key] = value.trim().toLowerCase();
        } else if (key == 'twitter') {
          normalized[key] = _normalizeTwitter(value);
        } else if (key == 'phone' ||
            key == 'linkedin' ||
            key == 'github' ||
            key == 'bio' ||
            key == 'firstName' ||
            key == 'lastName' ||
            key == 'company' ||
            key == 'role' ||
            key == 'avatarURL') {
          normalized[key] = value.trim();
        } else {
          normalized[key] = value.trim();
        }
      } else {
        normalized[key] = value;
      }
    }

    await _db.collection('users').doc(uid).set(
          normalized,
          SetOptions(merge: true),
        );

    final shouldUpdateDisplayName =
        normalized.containsKey('firstName') || normalized.containsKey('lastName');

    if (shouldUpdateDisplayName && _auth.currentUser?.uid == uid) {
      final userDoc = await _db.collection('users').doc(uid).get();
      final map = userDoc.data();
      if (map != null) {
        final profile = UserModel.fromMap(map);
        try {
          await _auth.currentUser?.updateDisplayName(profile.fullName);
        } catch (e) {
          Log.e('AUTH', 'Errore updateDisplayName', e);
        }
      }
    }
  }

  Future<void> saveFcmToken() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    try {
      final messaging = FirebaseMessaging.instance;

      await messaging.requestPermission();

      final token = await messaging.getToken();
      if (token == null || token.trim().isEmpty) return;

      await _db.collection('users').doc(uid).set({
        'fcmToken': token.trim(),
        'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      Log.e('AUTH', 'Errore salvataggio FCM token', e);
    }
  }

  static String? _normalizeOptional(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _normalizeTwitter(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return trimmed.startsWith('@') ? trimmed : '@$trimmed';
  }
}