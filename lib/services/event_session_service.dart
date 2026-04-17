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
/// È il SINGOLO punto di ingresso per entrare/uscire da un evento.
///
/// Singleton: usa [EventSessionService.instance].
class EventSessionService {
  EventSessionService._();
  static final EventSessionService instance = EventSessionService._();

  final _db = FirebaseFirestore.instance;

  String? _currentEventId;
  String? _sessionBleId;
  bool _isInEvent = false;

  String? get currentEventId => _currentEventId;
  String? get sessionBleId => _sessionBleId;
  bool get isInEvent => _isInEvent;

  Future<bool> joinEvent({
    required String eventId,
    required UserModel user,
  }) async {
    if (_isInEvent) await leaveEvent();

    final uid = user.uid;
    _sessionBleId =
        const Uuid().v4().replaceAll('-', '').substring(0, AppConstants.sessionBleIdLength);
    _currentEventId = eventId;

    Log.d('SESSION', 'Join evento $eventId con BLE ID $_sessionBleId');

    try {
      // bleMapping: sessionBleId → profilo (con dati estesi)
      await _db
          .collection('events')
          .doc(eventId)
          .collection('bleMapping')
          .doc(_sessionBleId!)
          .set({
        ...user.toSummary(),
        'sessionBleId': _sessionBleId,
        'joinedAt': FieldValue.serverTimestamp(),
      });

      // Presence
      await _db
          .collection('events')
          .doc(eventId)
          .collection('presence')
          .doc(uid)
          .set({
        'uid': uid,
        'sessionBleId': _sessionBleId,
        'displayName': user.fullName,
        'avatarURL': user.avatarURL,
        'joinedAt': FieldValue.serverTimestamp(),
        'lastSeen': FieldValue.serverTimestamp(),
        'isActive': true,
      });

      // Heartbeat
      PresenceHeartbeatService.instance.start(eventId: eventId, uid: uid);

      // BLE advertising
      final advOk = await BleAdvertiserService.instance.start(_sessionBleId!);
      if (!advOk) {
        Log.w('SESSION', 'Advertising non avviato (device non supportato?)');
      }

      // BLE scanning
      await BleScannerService.instance.start(mySessionBleId: _sessionBleId!);

      // Nearby detection
      await NearbyDetectionService.instance.start(
        eventId: eventId,
        myUid: uid,
        mySessionBleId: _sessionBleId!,
        scanner: BleScannerService.instance,
      );

      _isInEvent = true;
      Log.d('SESSION', 'Join completato');
      return true;
    } catch (e) {
      Log.e('SESSION', 'Errore join', e);
      await leaveEvent();
      return false;
    }
  }

  Future<void> leaveEvent() async {
    final eventId = _currentEventId;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    Log.d('SESSION', 'Leave evento $eventId');

    PresenceHeartbeatService.instance.stop();
    await BleAdvertiserService.instance.stop();
    await BleScannerService.instance.stop();
    NearbyDetectionService.instance.clear();

    if (eventId != null && uid != null) {
      try {
        await _db
            .collection('events')
            .doc(eventId)
            .collection('presence')
            .doc(uid)
            .update({
          'isActive': false,
          'leftAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        Log.e('SESSION', 'Errore update presence on leave', e);
      }

      if (_sessionBleId != null) {
        try {
          await _db
              .collection('events')
              .doc(eventId)
              .collection('bleMapping')
              .doc(_sessionBleId!)
              .delete();
        } catch (_) {}
      }
    }

    _currentEventId = null;
    _sessionBleId = null;
    _isInEvent = false;
    Log.d('SESSION', 'Leave completato');
  }
}
