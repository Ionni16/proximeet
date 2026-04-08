import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/user_model.dart';
import '../models/event_model.dart';
import '../models/connection_model.dart';
import 'nearby_detection_service.dart';
import 'event_session_service.dart';

class FirestoreService {
  static final FirestoreService shared = FirestoreService._();
  FirestoreService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ── UTENTI ──────────────────────────────────────────────

  Future<UserModel?> getUserByUid(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return UserModel.fromMap(doc.data()!);
  }

  // ── EVENTI ──────────────────────────────────────────────

  /// Stream di eventi attivi.
  Stream<List<EventModel>> listenToActiveEvents() {
    return _db
        .collection('events')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => EventModel.fromMap(d.id, d.data())).toList());
  }

  /// Singolo evento per id.
  Future<EventModel?> getEvent(String eventId) async {
    final doc = await _db.collection('events').doc(eventId).get();
    if (!doc.exists) return null;
    return EventModel.fromMap(doc.id, doc.data()!);
  }

  /// Conteggio presenti attivi ad un evento (per la UI lista eventi).
  Stream<int> listenToActiveCount(String eventId) {
    final twoMinAgo = Timestamp.fromDate(
      DateTime.now().subtract(const Duration(minutes: 2)),
    );
    return _db
        .collection('events')
        .doc(eventId)
        .collection('presence')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map((snap) => snap.docs.length);
  }

  // ── RICHIESTE CONTATTO ──────────────────────────────────

  /// Invia richiesta contatto. GATED: solo se l'utente è nearby recente.
  Future<void> sendConnectionRequest(String targetUid) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) throw Exception('Non autenticato');

    final eventId = EventSessionService.shared.currentEventId;
    if (eventId == null) throw Exception('Non sei in nessun evento');

    // GATING: verifica che targetUid sia stato rilevato via BLE di recente
    final isNearby =
        NearbyDetectionService.shared.isRecentlyDetected(targetUid);
    if (!isNearby) {
      // Fallback: controlla su Firestore
      final det = await _db
          .collection('events')
          .doc(eventId)
          .collection('detections')
          .doc(myUid)
          .collection('nearby')
          .doc(targetUid)
          .get();

      if (!det.exists) {
        throw Exception('Utente non rilevato nelle vicinanze');
      }
      final lastSeen = det.data()?['lastSeen'] as Timestamp?;
      if (lastSeen == null ||
          DateTime.now().difference(lastSeen.toDate()).inSeconds > 120) {
        throw Exception('Utente non più nelle vicinanze');
      }
    }

    // Controlla se già esiste una richiesta
    final existingId = '${myUid}_${targetUid}_$eventId';
    final existing =
        await _db.collection('connectionRequests').doc(existingId).get();
    if (existing.exists) {
      final status = existing.data()?['status'];
      if (status == 'pending') throw Exception('Richiesta già inviata');
      if (status == 'accepted') throw Exception('Già connessi');
    }

    await _db.collection('connectionRequests').doc(existingId).set({
      'senderUid': myUid,
      'receiverUid': targetUid,
      'eventId': eventId,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Rispondi a richiesta.
  Future<void> respondToRequest(String requestId, bool accepted) async {
    await _db.collection('connectionRequests').doc(requestId).update({
      'status': accepted ? 'accepted' : 'rejected',
      'respondedAt': FieldValue.serverTimestamp(),
    });

    if (accepted) {
      final doc =
          await _db.collection('connectionRequests').doc(requestId).get();
      final data = doc.data()!;
      final senderUid = data['senderUid'] as String;
      final receiverUid = data['receiverUid'] as String;
      final eventId = data['eventId'] as String? ?? '';

      // Recupera nome evento
      String eventName = '';
      if (eventId.isNotEmpty) {
        final ev = await getEvent(eventId);
        eventName = ev?.name ?? '';
      }

      await _saveToWallet(senderUid, receiverUid, eventName);
      await _saveToWallet(receiverUid, senderUid, eventName);
    }
  }

  Future<void> _saveToWallet(
      String ownerUid, String contactUid, String eventName) async {
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
      'eventName': eventName,
      'note': '',
    });
  }

  /// Ascolta richieste in arrivo per l'evento corrente.
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

  // ── WALLET ──────────────────────────────────────────────

  Stream<List<WalletContact>> listenToWallet() {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return Stream.value([]);

    return _db
        .collection('connections')
        .doc(myUid)
        .collection('contacts')
        .orderBy('connectedAt', descending: true)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => WalletContact.fromMap(d.data())).toList());
  }
}
