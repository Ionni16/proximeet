import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<UserCredential> login(String email, String password) async {
    return await _auth.signInWithEmailAndPassword(
      email: email,
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
    String? bio,
  }) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );

    final uid = credential.user!.uid;

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
      createdAt: DateTime.now(),
    );

    await _db.collection('users').doc(uid).set(user.toMap());
  }

  Future<void> logout() async {
    await _auth.signOut();
  }

  Future<UserModel?> getUserProfile(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return UserModel.fromMap(doc.data()!);
  }

  Future<void> updateAvatar(String uid, String avatarURL) async {
    await _db.collection('users').doc(uid).update({'avatarURL': avatarURL});
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
        await _db.collection('users').doc(uid).update({'fcmToken': token});
      }
    } catch (e) {
      print('[FCM] Errore: $e');
    }
  }
}
