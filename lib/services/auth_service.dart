import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import '../models/user_model.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // Utente corrente
  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Genera bleId dall'UID (come WLINK fa con major/minor ma più semplice)
  String _generateBleId(String uid) {
    final bytes = utf8.encode(uid);
    final hash = sha256.convert(bytes);
    return hash.toString().substring(0, 16);
  }

  // Login
  Future<UserCredential> login(String email, String password) async {
    return await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  // Registrazione
  Future<void> register({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
    required String company,
    required String role,
    String? phone,
    String? linkedin,
    String? bio,
  }) async {
    // 1. Crea utente su Firebase Auth
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );

    final uid = credential.user!.uid;
    final bleId = _generateBleId(uid);

    // 2. Salva profilo su Firestore
    final user = UserModel(
      uid: uid,
      firstName: firstName,
      lastName: lastName,
      email: email,
      company: company,
      role: role,
      avatarURL: '',
      linkedin: linkedin,
      phone: phone,
      bio: bio,
      bleId: bleId,
      createdAt: DateTime.now(),
    );

    await _db.collection('users').doc(uid).set(user.toMap());
  }

  // Logout
  Future<void> logout() async {
    await _auth.signOut();
  }

  // Recupera profilo utente
  Future<UserModel?> getUserProfile(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return UserModel.fromMap(doc.data()!);
  }

  Future<void> updateAvatar(String uid, String avatarURL) async {
    await _db.collection('users').doc(uid).update({
      'avatarURL': avatarURL,
    });
  }
  Future<void> updateProfile(String uid, Map<String, dynamic> data) async {
    await _db.collection('users').doc(uid).update(data);
  }

  Future<void> saveFcmToken() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await _db.collection('users').doc(uid).update({
          'fcmToken': token,
        });
        print('[FCM] Token salvato: $token');
      }
    } catch (e) {
      print('[FCM] Errore: $e');
    }
  }
}