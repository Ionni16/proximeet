import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../models/user_model.dart';
import 'ble_advertiser_service.dart';
import 'ble_scanner_service.dart';
import 'presence_heartbeat_service.dart';
import 'nearby_detection_service.dart';

/// Lifecycle completo di un utente dentro un evento:
/// join → BLE + presence + detection → leave/cleanup.
///
/// È il singolo punto di ingresso per entrare/uscire da un evento.
///
/// Singleton: usa [EventSessionService.instance].
class EventSessionService {
  EventSessionService._();
  static final EventSessionService instance = EventSessionService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String? _currentEventId;
  String? _sessionBleId;
  bool _isInEvent = false;

  bool _isJoining = false;
  bool _isLeaving = false;

  String? get currentEventId => _currentEventId;
  String? get sessionBleId => _sessionBleId;
  bool get isInEvent => _isInEvent;
  bool get isTransitioning => _isJoining || _isLeaving;
  bool get isJoining => _isJoining;
  bool get isLeaving => _isLeaving;

  Future<bool> joinEvent({
    required String eventId,
    required UserModel user,
  }) async {
    if (_isJoining || _isLeaving) {
      Log.w('SESSION', 'Join ignorato: transizione già in corso');
      return false;
    }

    _isJoining = true;

    try {
      if (_isInEvent) {
        await _performLeaveCleanup(markPresenceInactive: true);
      }

      final uid = user.uid;
      final newSessionBleId = const Uuid()
          .v4()
          .replaceAll('-', '')
          .substring(0, AppConstants.sessionBleIdLength);

      Log.d('SESSION', 'Join evento $eventId con BLE ID $newSessionBleId');

      _currentEventId = eventId;
      _sessionBleId = newSessionBleId;

      // 1) Mapping nearby minimale
      await _db
          .collection('events')
          .doc(eventId)
          .collection('bleMapping')
          .doc(newSessionBleId)
          .set({
        ...user.toSummary(),
        'sessionBleId': newSessionBleId,
        'joinedAt': FieldValue.serverTimestamp(),
      });

      // 2) Presence iniziale
      await _db
          .collection('events')
          .doc(eventId)
          .collection('presence')
          .doc(uid)
          .set({
        'uid': uid,
        'sessionBleId': newSessionBleId,
        'displayName': user.fullName,
        'avatarURL': user.avatarURL,
        'joinedAt': FieldValue.serverTimestamp(),
        'lastSeen': FieldValue.serverTimestamp(),
        'isActive': true,
      }, SetOptions(merge: true));

      // 3) Advertising
      final advOk = await BleAdvertiserService.instance.start(newSessionBleId);
      if (!advOk) {
        throw Exception('Advertising BLE non disponibile');
      }

      // 4) Scanning
      await BleScannerService.instance.start(
        mySessionBleId: newSessionBleId,
      );

      // 5) Detection
      await NearbyDetectionService.instance.start(
        eventId: eventId,
        myUid: uid,
        mySessionBleId: newSessionBleId,
        scanner: BleScannerService.instance,
      );

      // 6) Heartbeat solo alla fine
      PresenceHeartbeatService.instance.start(
        eventId: eventId,
        uid: uid,
      );

      _isInEvent = true;
      Log.d('SESSION', 'Join completato');
      return true;
    } catch (e) {
      Log.e('SESSION', 'Errore join', e);
      await _performLeaveCleanup(markPresenceInactive: true);
      return false;
    } finally {
      _isJoining = false;
    }
  }

  Future<void> leaveEvent() async {
    if (_isLeaving) {
      Log.w('SESSION', 'Leave ignorato: uscita già in corso');
      return;
    }

    _isLeaving = true;

    try {
      await _performLeaveCleanup(markPresenceInactive: true);
    } finally {
      _isLeaving = false;
    }
  }

  Future<void> _performLeaveCleanup({
    required bool markPresenceInactive,
  }) async {
    final eventId = _currentEventId;
    final sessionBleId = _sessionBleId;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    Log.d('SESSION', 'Cleanup evento=$eventId sessionBleId=$sessionBleId');

    try {
      PresenceHeartbeatService.instance.stop();

      try {
        await BleAdvertiserService.instance.stop();
      } catch (e) {
        Log.e('SESSION', 'Errore stop advertiser', e);
      }

      try {
        await BleScannerService.instance.stop();
      } catch (e) {
        Log.e('SESSION', 'Errore stop scanner', e);
      }

      try {
        NearbyDetectionService.instance.clear();
      } catch (e) {
        Log.e('SESSION', 'Errore clear nearby detection', e);
      }

      if (markPresenceInactive && eventId != null && uid != null) {
        try {
          await _db
              .collection('events')
              .doc(eventId)
              .collection('presence')
              .doc(uid)
              .set({
            'isActive': false,
            'leftAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (e) {
          Log.e('SESSION', 'Errore update presence on leave', e);
        }
      }

      if (eventId != null && sessionBleId != null) {
        try {
          await _db
              .collection('events')
              .doc(eventId)
              .collection('bleMapping')
              .doc(sessionBleId)
              .delete();
        } catch (e) {
          Log.e('SESSION', 'Errore delete bleMapping on leave', e);
        }
      }
    } finally {
      _currentEventId = null;
      _sessionBleId = null;
      _isInEvent = false;
      Log.d('SESSION', 'Cleanup completato');
    }
  }

  /// Aggiorna i dati del mio profilo nell'evento corrente.
  /// Da chiamare quando cambi avatar/bio/etc mentre sei dentro un evento,
  /// così gli altri partecipanti vedono subito le modifiche.
  Future<void> updateMyProfileInEvent(Map<String, dynamic> updates) async {
    final eventId = _currentEventId;
    final sessionBleId = _sessionBleId;

    if (eventId == null || sessionBleId == null) return;
    if (updates.isEmpty) return;

    // Profilo nearby pubblico: non propagare contatti privati.
    final safeUpdates = Map<String, dynamic>.from(updates)
      ..remove('email')
      ..remove('phone')
      ..remove('linkedin');

    if (safeUpdates.isEmpty) return;

    try {
      await _db
          .collection('events')
          .doc(eventId)
          .collection('bleMapping')
          .doc(sessionBleId)
          .update(safeUpdates);

      Log.d('SESSION', 'Profilo aggiornato in evento: $safeUpdates');
    } catch (e) {
      Log.e('SESSION', 'Errore update profilo evento', e);
    }
  }
}