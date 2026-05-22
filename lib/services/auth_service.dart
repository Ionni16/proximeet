import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../core/logger.dart';
import '../core/linkedin_config.dart';
import '../models/user_model.dart';

/// Risultato del login LinkedIn.
/// Se [isNewUser] è true, il caller deve mostrare la schermata
/// di completamento profilo (company, role, ecc.).
class LinkedInSignInResult {
  final UserCredential credential;
  final bool isNewUser;
  final Map<String, dynamic> linkedInProfile;

  const LinkedInSignInResult({
    required this.credential,
    required this.isNewUser,
    required this.linkedInProfile,
  });
}

/// Gestisce login, registrazione e aggiornamento profilo.
/// Singleton: usa sempre AuthService.instance.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

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

  // ── LINKEDIN LOGIN ──────────────────────────────────────────────────────────

  /// Completa il flusso OAuth LinkedIn:
  /// 1. Chiama la Cloud Function `linkedinAuth` con il codice OAuth
  /// 2. La Function scambia il codice con LinkedIn, crea l'utente Firebase
  /// 3. Fa il login con Custom Token
  ///
  /// Restituisce [LinkedInSignInResult] con:
  ///   - [isNewUser]: se true → mostrare schermata completamento profilo
  ///   - [linkedInProfile]: dati già disponibili da LinkedIn (nome, foto, email)
  Future<LinkedInSignInResult> signInWithLinkedIn(String authCode) async {
    try {
      // 1. Chiama la Cloud Function
      final callable = _functions.httpsCallable('linkedinAuth');
      final result = await callable.call({
        'code': authCode,
        'redirectUri': LinkedInConfig.redirectUri,
        'clientId': LinkedInConfig.clientId,
      });

      final data = result.data as Map<dynamic, dynamic>;
      final customToken = data['customToken'] as String;
      final isNewUser = data['isNewUser'] as bool? ?? true;
      final profile = Map<String, dynamic>.from(
        data['profile'] as Map<dynamic, dynamic>,
      );

      // 2. Login Firebase con custom token
      final credential = await _auth.signInWithCustomToken(customToken);

      Log.d('AUTH', 'LinkedIn login OK - uid: ${credential.user?.uid}, newUser: $isNewUser');

      return LinkedInSignInResult(
        credential: credential,
        isNewUser: isNewUser,
        linkedInProfile: profile,
      );
    } catch (e) {
      Log.e('AUTH', 'Errore LinkedIn signIn', e);
      rethrow;
    }
  }

  /// Crea il documento Firestore per un nuovo utente LinkedIn.
  /// Chiamato dalla schermata di completamento profilo.
  Future<void> createLinkedInUserProfile({
    required String uid,
    required String firstName,
    required String lastName,
    required String email,
    required String company,
    required String role,
    required String avatarURL,
    String? bio,
    String? phone,
    String? linkedinUrl,
  }) async {
    final user = UserModel(
      uid: uid,
      firstName: firstName.trim(),
      lastName: lastName.trim(),
      email: email.trim().toLowerCase(),
      company: company.trim(),
      role: role.trim(),
      avatarURL: avatarURL.trim(),
      linkedin: _normalizeOptional(linkedinUrl),
      bio: _normalizeOptional(bio),
      phone: _normalizeOptional(phone),
      createdAt: DateTime.now(),
    );

    await _db.collection('users').doc(uid).set(user.toMap());

    try {
      await _auth.currentUser?.updateDisplayName(user.fullName);
    } catch (e) {
      Log.e('AUTH', 'Errore updateDisplayName LinkedIn profile', e);
    }

    Log.d('AUTH', 'Profilo LinkedIn creato per uid: $uid');
  }

  // ── METODI ESISTENTI ────────────────────────────────────────────────────────

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

  /// Cambia la foto profilo e la propaga nel wallet di tutti i contatti.
  Future<void> updateAvatar(String uid, String avatarURL) async {
    final normalizedUrl = avatarURL.trim();

    await _db.collection('users').doc(uid).set({
      'avatarURL': normalizedUrl,
    }, SetOptions(merge: true));

    try {
      final myContactsSnap = await _db
          .collection('connections')
          .doc(uid)
          .collection('contacts')
          .get();

      if (myContactsSnap.docs.isEmpty) return;

      final batch = _db.batch();
      for (final contactDoc in myContactsSnap.docs) {
        final contactUid = contactDoc.data()['uid'] as String? ?? contactDoc.id;
        if (contactUid.isEmpty) continue;

        final myEntryRef = _db
            .collection('connections')
            .doc(contactUid)
            .collection('contacts')
            .doc(uid);

        batch.set(
          myEntryRef,
          {
            'avatarURL': normalizedUrl,
            'avatarUrl': normalizedUrl,
            'photoURL': normalizedUrl,
          },
          SetOptions(merge: true),
        );
      }

      await batch.commit();
      Log.d(
        'AUTH',
        'Avatar propagato a ${myContactsSnap.docs.length} contatti',
      );
    } catch (e) {
      Log.e('AUTH', 'Errore propagazione avatar ai contatti', e);
    }
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
