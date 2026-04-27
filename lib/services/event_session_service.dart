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
/// join → mapping/presence → proximity best-effort → heartbeat → leave/cleanup.
///
/// Regola importante: BLE/iBeacon NON deve bloccare l'ingresso evento.
/// iOS può richiedere permessi asincroni o avere Bluetooth/Location non pronti;
/// l'utente deve entrare comunque e il rilevamento parte appena possibile.
class EventSessionService {
  EventSessionService._();
  static final EventSessionService instance = EventSessionService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String? _currentEventId;
  String? _sessionBleId;
  bool _isInEvent = false;

  bool _isJoining = false;
  bool _isLeaving = false;
  String? _lastJoinError;

  String? get currentEventId => _currentEventId;
  String? get sessionBleId => _sessionBleId;
  bool get isInEvent => _isInEvent;
  bool get isTransitioning => _isJoining || _isLeaving;
  bool get isJoining => _isJoining;
  bool get isLeaving => _isLeaving;
  String? get lastJoinError => _lastJoinError;

  Future<bool> joinEvent({
    required String eventId,
    required UserModel user,
  }) async {
    if (_isJoining || _isLeaving) {
      _lastJoinError = 'Operazione già in corso. Riprova tra qualche secondo.';
      Log.w('SESSION', 'Join ignorato: transizione già in corso');
      return false;
    }

    _isJoining = true;
    _lastJoinError = null;

    try {
      if (_isInEvent) {
        await _performLeaveCleanup(markPresenceInactive: true);
      }

      final uid = user.uid;
      if (uid.isEmpty) {
        _lastJoinError = 'Utente non valido. Effettua di nuovo il login.';
        return false;
      }

      final raw = const Uuid().v4().replaceAll('-', '');
      final major = int.parse(raw.substring(0, 4), radix: 16);
      final minor = int.parse(raw.substring(4, 8), radix: 16);
      final newSessionBleId = AppConstants.beaconKey(major, minor);

      Log.d(
        'SESSION',
        'Join evento $eventId beaconKey=$newSessionBleId major=$major minor=$minor',
      );

      _currentEventId = eventId;
      _sessionBleId = newSessionBleId;

      await _writeSessionDocuments(
        eventId: eventId,
        user: user,
        sessionBleId: newSessionBleId,
        major: major,
        minor: minor,
      );

      // Da qui in poi l'utente è entrato nell'evento.
      // La parte proximity parte best-effort e non può più far fallire il join.
      _isInEvent = true;

      await _startProximityBestEffort(
        eventId: eventId,
        uid: uid,
        sessionBleId: newSessionBleId,
      );

      PresenceHeartbeatService.instance.start(
        eventId: eventId,
        uid: uid,
      );

      Log.d('SESSION', 'Join completato');
      return true;
    } catch (e, st) {
      _lastJoinError = _friendlyJoinError(e);
      Log.e('SESSION', 'Errore join', e, st);
      await _performLeaveCleanup(markPresenceInactive: true);
      return false;
    } finally {
      _isJoining = false;
    }
  }

  Future<void> _writeSessionDocuments({
    required String eventId,
    required UserModel user,
    required String sessionBleId,
    required int major,
    required int minor,
  }) async {
    final uid = user.uid;

    final mappingData = <String, dynamic>{
      ...user.toSummary(),
      'sessionBleId': sessionBleId,
      'beaconKey': sessionBleId,
      'major': major,
      'minor': minor,
      'beaconUuid': AppConstants.proximeetBeaconUuid,
      'joinedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final presenceData = <String, dynamic>{
      'uid': uid,
      'sessionBleId': sessionBleId,
      'beaconKey': sessionBleId,
      'major': major,
      'minor': minor,
      'beaconUuid': AppConstants.proximeetBeaconUuid,
      'displayName': user.fullName,
      'avatarURL': user.avatarURL,
      'joinedAt': FieldValue.serverTimestamp(),
      'lastSeen': FieldValue.serverTimestamp(),
      'isActive': true,
    };

    final batch = _db.batch();

    final mappingRef = _db
        .collection('events')
        .doc(eventId)
        .collection('bleMapping')
        .doc(sessionBleId);

    final presenceRef = _db
        .collection('events')
        .doc(eventId)
        .collection('presence')
        .doc(uid);

    batch.set(mappingRef, mappingData, SetOptions(merge: true));
    batch.set(presenceRef, presenceData, SetOptions(merge: true));

    await batch.commit();
  }

  Future<void> _startProximityBestEffort({
    required String eventId,
    required String uid,
    required String sessionBleId,
  }) async {
    try {
      final advOk = await BleAdvertiserService.instance.start(sessionBleId);
      if (!advOk) {
        Log.w(
          'SESSION',
          'Beacon non avviato. L ingresso evento continua comunque.',
        );
      }
    } catch (e, st) {
      Log.e('SESSION', 'Errore avvio beacon. Join non bloccato.', e, st);
    }

    try {
      await BleScannerService.instance.start(mySessionBleId: sessionBleId);
    } catch (e, st) {
      Log.e('SESSION', 'Errore avvio scanner. Join non bloccato.', e, st);
    }

    try {
      await NearbyDetectionService.instance.start(
        eventId: eventId,
        myUid: uid,
        mySessionBleId: sessionBleId,
        scanner: BleScannerService.instance,
      );
    } catch (e, st) {
      Log.e('SESSION', 'Errore avvio detection. Join non bloccato.', e, st);
    }
  }

  String _friendlyJoinError(Object e) {
    final text = e.toString();

    if (text.contains('permission-denied')) {
      return 'Permessi Firestore insufficienti per entrare in questo evento.';
    }
    if (text.contains('unavailable')) {
      return 'Connessione non disponibile. Controlla internet e riprova.';
    }
    if (text.contains('not-found')) {
      return 'Evento non trovato o non più disponibile.';
    }

    return 'Errore durante l ingresso all evento. Riprova.';
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
      } catch (e, st) {
        Log.e('SESSION', 'Errore stop advertiser', e, st);
      }

      try {
        await BleScannerService.instance.stop();
      } catch (e, st) {
        Log.e('SESSION', 'Errore stop scanner', e, st);
      }

      try {
        NearbyDetectionService.instance.clear();
      } catch (e, st) {
        Log.e('SESSION', 'Errore clear nearby detection', e, st);
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
        } catch (e, st) {
          Log.e('SESSION', 'Errore update presence on leave', e, st);
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
        } catch (e, st) {
          Log.e('SESSION', 'Errore delete bleMapping on leave', e, st);
        }
      }
    } finally {
      _currentEventId = null;
      _sessionBleId = null;
      _isInEvent = false;
      Log.d('SESSION', 'Cleanup completato');
    }
  }

  Future<void> updateMyProfileInEvent(Map<String, dynamic> updates) async {
    final eventId = _currentEventId;
    final sessionBleId = _sessionBleId;

    if (eventId == null || sessionBleId == null) return;
    if (updates.isEmpty) return;

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
          .update({
        ...safeUpdates,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      Log.d('SESSION', 'Profilo aggiornato in evento: $safeUpdates');
    } catch (e, st) {
      Log.e('SESSION', 'Errore update profilo evento', e, st);
    }
  }
}
