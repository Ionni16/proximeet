import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../core/logger.dart';
import '../core/linkedin_config.dart';
import '../models/user_model.dart';

/// Risultato del login LinkedIn.
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

/// Risultato del login Apple.
class AppleSignInResult {
  final UserCredential credential;
  final bool isNewUser;
  final String? email;
  final String? firstName;
  final String? lastName;

  const AppleSignInResult({
    required this.credential,
    required this.isNewUser,
    this.email,
    this.firstName,
    this.lastName,
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

  // ── APPLE SIGN IN ────────────────────────────────────────────────────────────

  /// Esegue il login con Sign in with Apple + Firebase.
  /// Restituisce [AppleSignInResult] con:
  ///   - [isNewUser]: se true → mostrare schermata completamento profilo
  ///   - email/firstName/lastName: disponibili SOLO alla prima autenticazione
  Future<AppleSignInResult> signInWithApple() async {
    // Genera nonce sicuro per prevenire replay attacks
    final rawNonce = _generateNonce();
    final nonce = _sha256ofString(rawNonce);

    try {
      // 1. Richiedi credenziale Apple
      final appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: nonce,
      );

      // 2. Verifica token Apple e crea credenziale OAuth Firebase.
      // Con firebase_auth 5.x è necessario passare anche authorizationCode
      // come accessToken, altrimenti Firebase può rispondere con
      // [firebase_auth/invalid-credential] Invalid OAuth response from apple.com.
      final identityToken = appleCredential.identityToken;
      final authorizationCode = appleCredential.authorizationCode;

      if (identityToken == null || identityToken.isEmpty) {
        throw FirebaseAuthException(
          code: 'missing-apple-id-token',
          message: 'Apple non ha restituito identityToken.',
        );
      }

      if (authorizationCode.isEmpty) {
        throw FirebaseAuthException(
          code: 'missing-apple-authorization-code',
          message: 'Apple non ha restituito authorizationCode.',
        );
      }

      _logAppleTokenClaims(identityToken);

      final oauthCredential = OAuthProvider('apple.com').credential(
        idToken: identityToken,
        rawNonce: rawNonce,
        accessToken: authorizationCode,
      );

      // 3. Login Firebase
      final userCredential = await _auth.signInWithCredential(oauthCredential);
      final firebaseUser = userCredential.user;
      if (firebaseUser == null) throw Exception('Login Apple fallito');

      final uid = firebaseUser.uid;

      // 4. Controlla se è nuovo utente
      final isNewUser = userCredential.additionalUserInfo?.isNewUser ?? false;

      // Email e nome: Apple li manda SOLO alla prima autenticazione
      final email = appleCredential.email ?? firebaseUser.email;
      final firstName = appleCredential.givenName;
      final lastName = appleCredential.familyName;

      // 5. Se nuovo utente e abbiamo dati minimi, salviamo subito email
      if (isNewUser && email != null) {
        await _db.collection('users').doc(uid).set({
          'email': email.trim().toLowerCase(),
          'firstName': firstName?.trim() ?? '',
          'lastName': lastName?.trim() ?? '',
          'avatarURL': firebaseUser.photoURL ?? '',
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      Log.d('AUTH', 'Apple login OK - uid: $uid, newUser: $isNewUser');

      return AppleSignInResult(
        credential: userCredential,
        isNewUser: isNewUser,
        email: email,
        firstName: firstName,
        lastName: lastName,
      );
    } catch (e) {
      Log.e('AUTH', 'Errore Apple signIn', e);
      rethrow;
    }
  }

  /// Genera un nonce casuale per Apple Sign In
  String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  /// SHA-256 del nonce
  String _sha256ofString(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }


  /// Logga solo i claim utili del JWT Apple, senza stampare il token completo.
  void _logAppleTokenClaims(String identityToken) {
    try {
      final parts = identityToken.split('.');
      if (parts.length != 3) return;

      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final decoded = jsonDecode(payload) as Map<String, dynamic>;

      Log.d(
        'AUTH',
        'Apple JWT claims: aud=${decoded['aud']}, '
        'iss=${decoded['iss']}, '
        'nonce=${decoded['nonce'] != null ? 'present' : 'missing'}, '
        'email=${decoded['email'] != null ? 'present' : 'missing'}',
      );
    } catch (e) {
      Log.e('AUTH', 'Impossibile leggere Apple JWT claims', e);
    }
  }

  // ── LINKEDIN LOGIN ──────────────────────────────────────────────────────────

  Future<LinkedInSignInResult> signInWithLinkedIn(String authCode) async {
    try {
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

  // ── METODI COMUNI ────────────────────────────────────────────────────────────

  Future<void> logout() async {
    await _auth.signOut();
  }

  /// Elimina permanentemente l'account dell'utente e tutti i suoi dati.
  ///
  /// Conforme alla App Store Guideline 5.1.1(v): la cancellazione è completa,
  /// avviata dall'utente e non richiede passaggi esterni.
  ///
  /// La logica pesante (dati Firestore, Storage, utente Auth) gira lato server
  /// nella Cloud Function `deleteAccount`, perché richiede privilegi admin per
  /// rimuovere l'utente anche dai wallet degli altri partecipanti.
  /// Dopo la cancellazione facciamo signOut per ripulire lo stato locale:
  /// lo StreamBuilder su authStateChanges riporterà automaticamente al login.
  Future<void> deleteAccount() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw FirebaseAuthException(
        code: 'no-current-user',
        message: 'Nessun utente autenticato.',
      );
    }

    // Chiama la Cloud Function che elimina tutti i dati lato server e
    // l'utente Auth. La logica di uscita dall'evento (stop BLE) è gestita
    // dal chiamante prima di invocare questo metodo.
    try {
      await _functions.httpsCallable('deleteAccount').call();
    } on FirebaseFunctionsException catch (e) {
      Log.e('AUTH', 'Errore Cloud Function deleteAccount', e);
      rethrow;
    }

    // L'utente Auth è già stato eliminato lato server: signOut ripulisce
    // solo la sessione locale e fa scattare il redirect al login.
    try {
      await _auth.signOut();
    } catch (e) {
      Log.e('AUTH', 'Errore signOut post-eliminazione', e);
    }

    Log.d('AUTH', 'Account eliminato e sessione locale ripulita');
  }

  Future<UserModel?> getUserProfile(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;

    final data = doc.data();
    if (data == null) return null;

    return UserModel.fromMap(data);
  }

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
      Log.d('AUTH', 'Avatar propagato a ${myContactsSnap.docs.length} contatti');
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
