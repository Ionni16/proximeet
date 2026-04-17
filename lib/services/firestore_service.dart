import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../models/user_model.dart';
import '../models/event_model.dart';
import '../models/connection_model.dart';
import 'nearby_detection_service.dart';
import 'event_session_service.dart';

/// Servizio Firestore centralizzato.
///
/// Singleton: usa [FirestoreService.instance].
class FirestoreService {
  FirestoreService._();
  static final FirestoreService instance = FirestoreService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ── UTENTI ──────────────────────────────────────────────

  Future<UserModel?> getUserByUid(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return UserModel.fromMap(doc.data()!);
  }

  // ── EVENTI ──────────────────────────────────────────────

  Stream<List<EventModel>> listenToActiveEvents() {
    return _db
        .collection('events')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => EventModel.fromMap(d.id, d.data())).toList());
  }

  Future<EventModel?> getEvent(String eventId) async {
    final doc = await _db.collection('events').doc(eventId).get();
    if (!doc.exists) return null;
    return EventModel.fromMap(doc.id, doc.data()!);
  }

  /// Conteggio presenti attivi — filtra solo `isActive == true`.
  ///
  /// FIX: il vecchio codice calcolava `twoMinAgo` una volta sola
  /// al momento della subscription. Ora filtriamo solo per isActive
  /// che viene aggiornato dal heartbeat e dal leave.
  Stream<int> listenToActiveCount(String eventId) {
    return _db
        .collection('events')
        .doc(eventId)
        .collection('presence')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map((snap) => snap.docs.length);
  }

  // ── RICHIESTE CONTATTO ──────────────────────────────────

  /// Invia richiesta contatto. Gated: solo se l'utente è nearby.
  Future<void> sendConnectionRequest(String targetUid) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) throw Exception('Non autenticato');

    final eventId = EventSessionService.instance.currentEventId;
    if (eventId == null) throw Exception('Non sei in nessun evento');

    // Gating BLE: verifica vicinanza
    final isNearby = NearbyDetectionService.instance.isRecentlyDetected(
      targetUid,
      maxSeconds: AppConstants.contactGatingSeconds,
    );

    if (!isNearby) {
      // Fallback Firestore
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
          DateTime.now().difference(lastSeen.toDate()).inSeconds >
              AppConstants.contactGatingSeconds) {
        throw Exception('Utente non più nelle vicinanze');
      }
    }

    // Check duplicati
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
  ///
  /// FIX: il wallet viene scritto SOLO qui (client-side).
  /// La Cloud Function gestisce solo notifiche push — non scrive wallet,
  /// così evitiamo duplicati.
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
    String ownerUid,
    String contactUid,
    String eventName,
  ) async {
    final profile = await getUserByUid(contactUid);
    if (profile == null) return;

    await _db
        .collection('connections')
        .doc(ownerUid)
        .collection('contacts')
        .doc(contactUid)
        .set({
      'uid': contactUid,
      'firstName': profile.firstName,
      'lastName': profile.lastName,
      'company': profile.company,
      'role': profile.role,
      'email': profile.email,
      'phone': profile.phone ?? '',
      'linkedin': profile.linkedin ?? '',
      'avatarURL': profile.avatarURL,
      'connectedAt': FieldValue.serverTimestamp(),
      'eventName': eventName,
      'note': '',
    });
  }

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
