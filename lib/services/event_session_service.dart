import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

import '../core/app_debug_error.dart';
import '../core/constants.dart';
import '../core/logger.dart';
import '../models/user_model.dart';
import 'ble_advertiser_service.dart';
import 'ble_scanner_service.dart';
import 'debug_error_service.dart';
import 'nearby_detection_service.dart';
import 'presence_heartbeat_service.dart';

/// Gestisce la sessione evento e il token BLE GATT temporaneo.
class EventSessionService {
  EventSessionService._();

  static final EventSessionService shared = EventSessionService._();
  static EventSessionService get instance => shared;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String? _currentEventId;
  String? _sessionBleId; // compat: ora contiene proximity token
  bool _isInEvent = false;
  String? _lastJoinError;
  AppDebugError? _lastJoinDebugError;

  String? get currentEventId => _currentEventId;
  String? get sessionBleId => _sessionBleId;
  bool get isInEvent => _isInEvent;
  String? get lastJoinError => _lastJoinError;
  AppDebugError? get lastJoinDebugError => _lastJoinDebugError;

  Future<bool> joinEvent({
    required String eventId,
    required UserModel user,
  }) async {
    _lastJoinError = null;
    _lastJoinDebugError = null;

    if (_isInEvent) await leaveEvent();

    final uid = user.uid;
    final token = _generateEphemeralToken();

    _currentEventId = eventId;
    _sessionBleId = token;

    Log.d('SESSION', 'Join evento $eventId con token ${_redact(token)}');

    try {
      await _writeProximityToken(eventId: eventId, user: user, token: token);
      await _writePresence(eventId: eventId, uid: uid, user: user, token: token);

      PresenceHeartbeatService.instance.start(eventId: eventId, uid: uid);
      _isInEvent = true;

      // Importante per rilevamento rapido: il listener Dart deve essere attivo
      // prima che il plugin nativo inizi a emettere gattPeer. Altrimenti le prime
      // detection possono perdersi e l'utente vede il peer solo dopo retry successivi.
      await _startNearbyBestEffort(eventId: eventId, uid: uid, token: token);
      await _startBleGattBestEffort(token);

      Log.d('SESSION', 'Join completato con successo');
      return true;
    } catch (e, st) {
      _lastJoinDebugError = DebugErrorService.instance.fromException(
        area: 'SESSION_JOIN',
        fallbackTitle: 'Ingresso evento non riuscito',
        fallbackMessage:
            'Non è stato possibile completare la scrittura della sessione evento.',
        fallbackSuggestion:
            'Controlla autenticazione, Firestore Rules, eventId e connessione internet.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'eventId': eventId,
          'uid': uid,
          'token': _redact(token),
          'isInEventBeforeCleanup': _isInEvent,
        },
      );
      _lastJoinError = _lastJoinDebugError!.title;
      await leaveEvent();
      return false;
    }
  }

  Future<void> _writeProximityToken({
    required String eventId,
    required UserModel user,
    required String token,
  }) async {
    final expiresAt = Timestamp.fromDate(
      DateTime.now().add(
        const Duration(seconds: AppConstants.proximityTokenTtlSeconds),
      ),
    );

    try {
      await _db
          .collection('events')
          .doc(eventId)
          .collection('proximityTokens')
          .doc(token)
          .set({
        ...user.toSummary(),
        'sessionBleId': token,
        'token': token,
        'transport': 'ble_gatt',
        'serviceUuid': AppConstants.proximeetGattServiceUuid,
        'characteristicUuid': AppConstants.proximeetGattTokenCharacteristicUuid,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'expiresAt': expiresAt,
        'active': true,
      });
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'FIRESTORE_PROXIMITY_TOKEN',
        fallbackTitle: 'Errore scrittura proximity token',
        fallbackMessage: 'Firestore non ha scritto il mapping token → utente.',
        fallbackSuggestion:
            'Controlla le rules su events/{eventId}/proximityTokens/{token}.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'eventId': eventId,
          'token': _redact(token),
          'collection': 'events/$eventId/proximityTokens/{token}',
        },
      );
      rethrow;
    }
  }

  Future<void> _writePresence({
    required String eventId,
    required String uid,
    required UserModel user,
    required String token,
  }) async {
    try {
      await _db
          .collection('events')
          .doc(eventId)
          .collection('presence')
          .doc(uid)
          .set({
        'uid': uid,
        'sessionBleId': token,
        'proximityToken': token,
        'transport': 'ble_gatt',
        'displayName': user.fullName,
        'avatarURL': user.avatarURL,
        'company': user.company,
        'role': user.role,
        'bio': user.bio ?? '',
        'joinedAt': FieldValue.serverTimestamp(),
        'lastSeen': FieldValue.serverTimestamp(),
        'isActive': true,
      }, SetOptions(merge: true));
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'FIRESTORE_PRESENCE',
        fallbackTitle: 'Errore scrittura presenza',
        fallbackMessage:
            'Firestore non ha scritto la presenza dell’utente nell’evento.',
        fallbackSuggestion: 'Controlla le rules su events/{eventId}/presence/{uid}.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'eventId': eventId,
          'uid': uid,
          'token': _redact(token),
        },
      );
      rethrow;
    }
  }

  String _generateEphemeralToken() {
    final raw = const Uuid().v4().replaceAll('-', '');
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    return 'pm:$ts:$raw';
  }

  Future<void> _startBleGattBestEffort(String token) async {
    try {
      final ok = await BleAdvertiserService.shared.start(token);
      if (!ok) {
        DebugErrorService.instance.add(AppDebugError(
          title: 'BLE GATT non avviato',
          area: 'BLE_GATT_START',
          code: 'BLE_GATT_START_FALSE',
          message:
              'Il plugin nativo ha restituito false durante l’avvio BLE GATT.',
          suggestion:
              'Controlla permessi Bluetooth/Location e log nativi. Il join continua comunque.',
          data: <String, Object?>{'token': _redact(token)},
        ));
      }

      await BleScannerService.shared.start(mySessionBleId: token);
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'BLE_GATT_START',
        fallbackTitle: 'Errore avvio BLE GATT',
        fallbackMessage:
            'Il join evento è riuscito, ma il trasporto BLE GATT non è partito.',
        fallbackSuggestion:
            'Controlla Bluetooth, Localizzazione/Nearby Devices e plugin nativi.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{'token': _redact(token)},
      );
    }
  }

  Future<void> _startNearbyBestEffort({
    required String eventId,
    required String uid,
    required String token,
  }) async {
    try {
      await NearbyDetectionService.instance.start(
        eventId: eventId,
        myUid: uid,
        mySessionBleId: token,
        scanner: BleScannerService.shared,
      );
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'NEARBY_START',
        fallbackTitle: 'Errore avvio rilevamento vicini',
        fallbackMessage:
            'Il join evento è riuscito, ma NearbyDetectionService non è partito.',
        fallbackSuggestion: 'Controlla stream scanner, proximityTokens e log BLE_GATT.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'eventId': eventId,
          'uid': uid,
          'token': _redact(token),
        },
      );
    }
  }

  Future<void> updateMyProfileInEvent(Map<String, dynamic> summary) async {
    final eventId = _currentEventId;
    final token = _sessionBleId;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (eventId == null || uid == null) {
      DebugErrorService.instance.add(AppDebugError(
        title: 'Profilo evento non aggiornato',
        area: 'PROFILE_UPDATE',
        code: 'NO_ACTIVE_EVENT',
        message: 'Non esiste una sessione evento attiva oppure manca uid.',
        suggestion: 'Entra in un evento prima di aggiornare il profilo.',
        data: <String, Object?>{'eventId': eventId, 'uid': uid, 'token': token},
      ));
      return;
    }

    final safeSummary = Map<String, dynamic>.from(summary)
      ..removeWhere((key, value) => value == null);

    try {
      await _db.collection('events').doc(eventId).collection('presence').doc(uid).set({
        ...safeSummary,
        'uid': uid,
        'lastSeen': FieldValue.serverTimestamp(),
        'isActive': true,
      }, SetOptions(merge: true));

      if (token != null) {
        await _db
            .collection('events')
            .doc(eventId)
            .collection('proximityTokens')
            .doc(token)
            .set({
          ...safeSummary,
          'uid': uid,
          'sessionBleId': token,
          'token': token,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      Log.d('SESSION', 'Profilo evento aggiornato');
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'PROFILE_UPDATE',
        fallbackTitle: 'Errore aggiornamento profilo evento',
        fallbackMessage: 'Non è stato possibile aggiornare presence/proximityTokens.',
        fallbackSuggestion: 'Controlla Firestore Rules su presence e proximityTokens.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'eventId': eventId,
          'uid': uid,
          'token': token == null ? null : _redact(token),
          'summary': safeSummary,
        },
      );
      rethrow;
    }
  }

  Future<void> leaveEvent() async {
    final eventId = _currentEventId;
    final token = _sessionBleId;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    Log.d('SESSION', 'Leave evento $eventId');

    PresenceHeartbeatService.instance.stop();

    try {
      await BleAdvertiserService.shared.stop();
      await BleScannerService.shared.stop();
      NearbyDetectionService.instance.clear();
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'SESSION_LEAVE_LOCAL',
        fallbackTitle: 'Errore stop servizi locali',
        fallbackMessage: 'Errore durante lo stop di BLE/Nearby.',
        fallbackSuggestion: 'Controlla PlatformBeaconService.stop().',
        error: e,
        stackTrace: st,
      );
    }

    if (eventId != null && uid != null) {
      try {
        await _db.collection('events').doc(eventId).collection('presence').doc(uid).set({
          'isActive': false,
          'leftAt': FieldValue.serverTimestamp(),
          'lastSeen': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e, st) {
        DebugErrorService.instance.fromException(
          area: 'FIRESTORE_LEAVE_PRESENCE',
          fallbackTitle: 'Errore aggiornamento uscita evento',
          fallbackMessage: 'Non è stato possibile segnare isActive=false.',
          fallbackSuggestion: 'Controlla rules Firestore su presence/{uid}.',
          error: e,
          stackTrace: st,
          data: <String, Object?>{'eventId': eventId, 'uid': uid},
        );
      }

      if (token != null) {
        try {
          await _db
              .collection('events')
              .doc(eventId)
              .collection('proximityTokens')
              .doc(token)
              .set({
            'active': false,
            'leftAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (e, st) {
          DebugErrorService.instance.fromException(
            area: 'FIRESTORE_LEAVE_PROXIMITY_TOKEN',
            fallbackTitle: 'Errore disattivazione proximity token',
            fallbackMessage: 'Non è stato possibile disattivare il token BLE.',
            fallbackSuggestion: 'Controlla rules Firestore su proximityTokens/{token}.',
            error: e,
            stackTrace: st,
            data: <String, Object?>{'eventId': eventId, 'token': _redact(token)},
          );
        }
      }
    }

    _currentEventId = null;
    _sessionBleId = null;
    _isInEvent = false;

    Log.d('SESSION', 'Leave completato');
  }

  String _redact(String value) {
    if (value.length <= 10) return '***';
    return '${value.substring(0, 6)}…${value.substring(value.length - 4)}';
  }
}
