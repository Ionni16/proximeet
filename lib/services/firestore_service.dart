import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/user_model.dart';
import '../models/connection_model.dart';

class FirestoreService {
  static final FirestoreService shared = FirestoreService._();
  FirestoreService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // Recupera profilo utente per uid
  Future<UserModel?> getUserByUid(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return UserModel.fromMap(doc.data()!);
  }

  // Recupera profilo utente per bleId
  Future<UserModel?> getUserByBleId(String bleId) async {
    final snap = await _db
        .collection('users')
        .where('bleId', isEqualTo: bleId)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    return UserModel.fromMap(snap.docs.first.data());
  }

  // Invia richiesta biglietto
  Future<void> sendConnectionRequest(String targetUid) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;

    await _db
        .collection('connectionRequests')
        .doc('${myUid}_$targetUid')
        .set({
      'senderUid': myUid,
      'receiverUid': targetUid,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // Rispondi a richiesta
  Future<void> respondToRequest(String requestId, bool accepted) async {
    await _db
        .collection('connectionRequests')
        .doc(requestId)
        .update({
      'status': accepted ? 'accepted' : 'rejected',
      'respondedAt': FieldValue.serverTimestamp(),
    });

    // Se accettata salva nel wallet di entrambi
    if (accepted) {
      final doc = await _db
          .collection('connectionRequests')
          .doc(requestId)
          .get();
      final data = doc.data()!;
      final senderUid = data['senderUid'] as String;
      final receiverUid = data['receiverUid'] as String;
      await _saveToWallet(senderUid, receiverUid);
      await _saveToWallet(receiverUid, senderUid);
    }
  }

  // Salva contatto nel wallet
  Future<void> _saveToWallet(String ownerUid, String contactUid) async {
    final contactProfile = await getUserByUid(contactUid);
    if (contactProfile == null) return;

    await _db
        .collection('connections')
        .doc(ownerUid)
        .collection('contacts')
        .doc(contactUid)
        .set({
      'uid': contactUid,
      'firstName': contactProfile.firstName,
      'lastName': contactProfile.lastName,
      'company': contactProfile.company,
      'role': contactProfile.role,
      'email': contactProfile.email,
      'phone': contactProfile.phone ?? '',
      'linkedin': contactProfile.linkedin ?? '',
      'avatarURL': contactProfile.avatarURL,
      'connectedAt': FieldValue.serverTimestamp(),
      'note': '',
    });
  }

  // Ascolta richieste in arrivo
  Stream<List<ConnectionRequest>> listenToIncomingRequests() {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return Stream.value([]);

    return _db
        .collection('connectionRequests')
        .where('receiverUid', isEqualTo: myUid)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => ConnectionRequest.fromMap(d.id, d.data()))
            .toList());
  }

  // Ascolta wallet
  Stream<List<WalletContact>> listenToWallet() {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return Stream.value([]);

    return _db
        .collection('connections')
        .doc(myUid)
        .collection('contacts')
        .orderBy('connectedAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => WalletContact.fromMap(d.data()))
            .toList());
  }

  // Controlla se già connessi
  Future<String?> getConnectionStatus(String targetUid) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return null;

    final doc = await _db
        .collection('connectionRequests')
        .doc('${myUid}_$targetUid')
        .get();

    if (!doc.exists) return null;
    return doc.data()?['status'] as String?;
  }
}