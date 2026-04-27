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

    final data = doc.data();
    if (data == null) return null;

    return UserModel.fromMap(data);
  }

  // ── EVENTI ──────────────────────────────────────────────

  Stream<List<EventModel>> listenToActiveEvents() {
    return _db
        .collection('events')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => EventModel.fromMap(d.id, d.data()))
              .toList(),
        );
  }

  Future<EventModel?> getEvent(String eventId) async {
    final doc = await _db.collection('events').doc(eventId).get();
    if (!doc.exists) return null;

    final data = doc.data();
    if (data == null) return null;

    return EventModel.fromMap(doc.id, data);
  }

  /// Conteggio presenti attivi.
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

  /// Invia richiesta contatto. Consentita solo se l'utente è nearby
  /// o è stato rilevato di recente nei dati detection.
  Future<void> sendConnectionRequest(String targetUid) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) {
      throw Exception('Non autenticato');
    }

    if (targetUid == myUid) {
      throw Exception('Non puoi inviare una richiesta a te stesso');
    }

    final eventId = EventSessionService.instance.currentEventId;
    if (eventId == null) {
      throw Exception('Non sei in nessun evento');
    }

    final isNearby = NearbyDetectionService.instance.isRecentlyDetected(
      targetUid,
      maxSeconds: AppConstants.contactGatingSeconds,
    );

    if (!isNearby) {
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

      final data = det.data();
      final lastSeen = data?['lastSeen'] as Timestamp?;
      final rssi = (data?['rssi'] as num?)?.toInt();

      if (lastSeen == null ||
          DateTime.now().difference(lastSeen.toDate()).inSeconds >
              AppConstants.contactGatingSeconds) {
        throw Exception('Utente non più nelle vicinanze');
      }

      if (rssi == null || rssi < AppConstants.rssiMedium) {
        throw Exception('Segnale troppo debole per inviare la richiesta');
      }
    }

    final requestId = '${myUid}_${targetUid}_$eventId';
    final requestRef = _db.collection('connectionRequests').doc(requestId);

    await _db.runTransaction((tx) async {
      final existing = await tx.get(requestRef);

      if (existing.exists) {
        final status = existing.data()?['status'] as String?;

        if (status == 'pending') {
          throw Exception('Richiesta già inviata');
        }
        if (status == 'accepted') {
          throw Exception('Già connessi');
        }
      }

      tx.set(requestRef, {
        'senderUid': myUid,
        'receiverUid': targetUid,
        'eventId': eventId,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtClient': Timestamp.now(),
      });
    });
  }

  /// Rispondi a richiesta.
  ///
  /// Il wallet viene scritto solo qui lato client.
  /// La funzione è resa idempotente: se la richiesta è già stata gestita,
  /// non la duplichiamo.
  Future<void> respondToRequest(String requestId, bool accepted) async {
    final requestRef = _db.collection('connectionRequests').doc(requestId);

    late final Map<String, dynamic> requestData;

    await _db.runTransaction((tx) async {
      final snap = await tx.get(requestRef);

      if (!snap.exists) {
        throw Exception('Richiesta non trovata');
      }

      final data = snap.data();
      if (data == null) {
        throw Exception('Richiesta non valida');
      }

      final status = data['status'] as String? ?? 'pending';

      if (status != 'pending') {
        throw Exception(
          status == 'accepted'
              ? 'Richiesta già accettata'
              : 'Richiesta già gestita',
        );
      }

      requestData = Map<String, dynamic>.from(data);

      tx.update(requestRef, {
        'status': accepted ? 'accepted' : 'rejected',
        'respondedAt': FieldValue.serverTimestamp(),
        'respondedAtClient': Timestamp.now(),
      });
    });

    if (!accepted) return;

    final senderUid = requestData['senderUid'] as String? ?? '';
    final receiverUid = requestData['receiverUid'] as String? ?? '';
    final eventId = requestData['eventId'] as String? ?? '';

    if (senderUid.isEmpty || receiverUid.isEmpty) {
      throw Exception('Dati richiesta incompleti');
    }

    String eventName = '';
    if (eventId.isNotEmpty) {
      final event = await getEvent(eventId);
      eventName = event?.name ?? '';
    }

    await _saveToWallet(senderUid, receiverUid, eventName);
    await _saveToWallet(receiverUid, senderUid, eventName);
  }

  Future<void> _saveToWallet(
    String ownerUid,
    String contactUid,
    String eventName,
  ) async {
    final profile = await getUserByUid(contactUid);
    if (profile == null) {
      Log.w('FIRESTORE', 'Profilo contatto non trovato: $contactUid');
      return;
    }

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
      'avatarURL': profile.avatarURL.trim(),
      'avatarUrl': profile.avatarURL.trim(),
      'photoURL': profile.avatarURL.trim(),
      'connectedAt': FieldValue.serverTimestamp(),
      'connectedAtClient': Timestamp.now(),
      'eventName': eventName,
      'note': '',
    }, SetOptions(merge: true));
  }

  Stream<List<ConnectionRequest>> listenToIncomingRequests() {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return Stream.value([]);

    return _db
        .collection('connectionRequests')
        .where('receiverUid', isEqualTo: myUid)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => ConnectionRequest.fromMap(d.id, d.data()))
              .toList(),
        );
  }

  // ── WALLET ──────────────────────────────────────────────

  Future<WalletContact> _hydrateWalletContactWithLiveProfile(
    WalletContact contact,
  ) async {
    try {
      final profile = await getUserByUid(contact.uid);

      if (profile == null) {
        return contact;
      }

      final liveAvatarURL = profile.avatarURL.trim();

      if (liveAvatarURL.isEmpty) {
        return contact;
      }

      return WalletContact(
        uid: contact.uid,
        firstName: profile.firstName.isNotEmpty
            ? profile.firstName
            : contact.firstName,
        lastName: profile.lastName.isNotEmpty
            ? profile.lastName
            : contact.lastName,
        company: profile.company.isNotEmpty
            ? profile.company
            : contact.company,
        role: profile.role.isNotEmpty
            ? profile.role
            : contact.role,
        email: profile.email.isNotEmpty
            ? profile.email
            : contact.email,
        phone: profile.phone?.isNotEmpty == true
            ? profile.phone!
            : contact.phone,
        linkedin: profile.linkedin?.isNotEmpty == true
            ? profile.linkedin!
            : contact.linkedin,
        avatarURL: liveAvatarURL,
        connectedAt: contact.connectedAt,
        eventName: contact.eventName,
        note: contact.note,
      );
    } catch (e, st) {
      Log.e(
        'FIRESTORE',
        'Errore refresh profilo wallet ${contact.uid}',
        e,
        st,
      );

      return contact;
    }
  }

  Stream<List<WalletContact>> listenToWallet() {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return Stream.value([]);

    return _db
        .collection('connections')
        .doc(myUid)
        .collection('contacts')
        .orderBy('connectedAt', descending: true)
        .snapshots()
        .asyncMap((snap) async {
      final contacts = snap.docs
          .map((d) => WalletContact.fromMap(d.data()))
          .toList();

      final hydratedContacts = await Future.wait(
        contacts.map(_hydrateWalletContactWithLiveProfile),
      );

      return hydratedContacts;
    });
  }
}