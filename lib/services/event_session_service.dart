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

class EventSessionService {
  EventSessionService._();

  static final EventSessionService shared = EventSessionService._();

  static EventSessionService get instance => shared;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String? _currentEventId;
  String? _sessionBleId;
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

    if (_isInEvent) {
      await leaveEvent();
    }

    final uid = user.uid;
    final beaconKey = _generateBeaconKey();

    _currentEventId = eventId;
    _sessionBleId = beaconKey;

    Log.d('SESSION', 'Join evento $eventId con beaconKey $beaconKey');

    try {
      final parsed = AppConstants.parseBeaconKey(beaconKey);

      await _writeBleMapping(
        eventId: eventId,
        user: user,
        beaconKey: beaconKey,
        major: parsed.major,
        minor: parsed.minor,
      );

      await _writePresence(
        eventId: eventId,
        uid: uid,
        user: user,
        beaconKey: beaconKey,
        major: parsed.major,
        minor: parsed.minor,
      );

      PresenceHeartbeatService.instance.start(eventId: eventId, uid: uid);

      _isInEvent = true;

      await _startBeaconBestEffort(beaconKey);
      await _startNearbyBestEffort(
        eventId: eventId,
        uid: uid,
        beaconKey: beaconKey,
      );

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
          'beaconKey': beaconKey,
          'isInEventBeforeCleanup': _isInEvent,
        },
      );
      _lastJoinError = _lastJoinDebugError!.title;

      await leaveEvent();
      return false;
    }
  }

  Future<void> _writeBleMapping({
    required String eventId,
    required UserModel user,
    required String beaconKey,
    required int major,
    required int minor,
  }) async {
    try {
      await _db
          .collection('events')
          .doc(eventId)
          .collection('bleMapping')
          .doc(beaconKey)
          .set({
            ...user.toSummary(),
            'sessionBleId': beaconKey,
            'beaconKey': beaconKey,
            'major': major,
            'minor': minor,
            'beaconUuid': AppConstants.proximeetBeaconUuid,
            'joinedAt': FieldValue.serverTimestamp(),
          });
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'FIRESTORE_BLE_MAPPING',
        fallbackTitle: 'Errore scrittura bleMapping',
        fallbackMessage: 'Firestore non ha scritto il mapping beacon → utente.',
        fallbackSuggestion:
            'Controlla le rules su events/{eventId}/bleMapping/{beaconKey}.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'eventId': eventId,
          'beaconKey': beaconKey,
          'major': major,
          'minor': minor,
          'collection': 'events/$eventId/bleMapping/$beaconKey',
        },
      );
      rethrow;
    }
  }

  Future<void> _writePresence({
    required String eventId,
    required String uid,
    required UserModel user,
    required String beaconKey,
    required int major,
    required int minor,
  }) async {
    try {
      await _db
          .collection('events')
          .doc(eventId)
          .collection('presence')
          .doc(uid)
          .set({
            'uid': uid,
            'sessionBleId': beaconKey,
            'beaconKey': beaconKey,
            'major': major,
            'minor': minor,
            'displayName': user.fullName,
            'avatarURL': user.avatarURL,
            'joinedAt': FieldValue.serverTimestamp(),
            'lastSeen': FieldValue.serverTimestamp(),
            'isActive': true,
          });
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'FIRESTORE_PRESENCE',
        fallbackTitle: 'Errore scrittura presenza',
        fallbackMessage:
            'Firestore non ha scritto la presenza dell’utente nell’evento.',
        fallbackSuggestion:
            'Controlla le rules su events/{eventId}/presence/{uid}.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'eventId': eventId,
          'uid': uid,
          'beaconKey': beaconKey,
          'collection': 'events/$eventId/presence/$uid',
        },
      );
      rethrow;
    }
  }

  String _generateBeaconKey() {
    final raw = const Uuid().v4().replaceAll('-', '');
    final major = int.parse(raw.substring(0, 4), radix: 16);
    final minor = int.parse(raw.substring(4, 8), radix: 16);
    return AppConstants.beaconKey(major, minor);
  }

  Future<void> _startBeaconBestEffort(String beaconKey) async {
    try {
      final advOk = await BleAdvertiserService.shared.start(beaconKey);

      if (!advOk) {
        DebugErrorService.instance.add(
          AppDebugError(
            title: 'Beacon non avviato',
            area: 'BEACON_START',
            code: 'BEACON_START_FALSE',
            message:
                'Il plugin nativo ha restituito false durante l’avvio beacon.',
            suggestion:
                'Controlla permessi Bluetooth/Location e log nativi. Il join continua comunque.',
            data: <String, Object?>{'beaconKey': beaconKey},
          ),
        );
      }

      await BleScannerService.shared.start(mySessionBleId: beaconKey);
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'BEACON_START',
        fallbackTitle: 'Errore avvio beacon',
        fallbackMessage: 'Il join evento è riuscito, ma iBeacon non è partito.',
        fallbackSuggestion:
            'Controlla Bluetooth, Localizzazione, AppDelegate.swift e PlatformBeaconService.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{'beaconKey': beaconKey},
      );
    }
  }

  Future<void> _startNearbyBestEffort({
    required String eventId,
    required String uid,
    required String beaconKey,
  }) async {
    try {
      await NearbyDetectionService.instance.start(
        eventId: eventId,
        myUid: uid,
        mySessionBleId: beaconKey,
        scanner: BleScannerService.shared,
      );
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'NEARBY_START',
        fallbackTitle: 'Errore avvio rilevamento vicini',
        fallbackMessage:
            'Il join evento è riuscito, ma NearbyDetectionService non è partito.',
        fallbackSuggestion:
            'Controlla stream scanner, bleMapping e log BEACON.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'eventId': eventId,
          'uid': uid,
          'beaconKey': beaconKey,
        },
      );
    }
  }

  Future<void> updateMyProfileInEvent(Map<String, dynamic> summary) async {
    final eventId = _currentEventId;
    final sessionBleId = _sessionBleId;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (eventId == null || uid == null) {
      DebugErrorService.instance.add(
        AppDebugError(
          title: 'Profilo evento non aggiornato',
          area: 'PROFILE_UPDATE',
          code: 'NO_ACTIVE_EVENT',
          message: 'Non esiste una sessione evento attiva oppure manca uid.',
          suggestion: 'Entra in un evento prima di aggiornare il profilo.',
          data: <String, Object?>{
            'eventId': eventId,
            'uid': uid,
            'sessionBleId': sessionBleId,
          },
        ),
      );
      return;
    }

    final safeSummary = Map<String, dynamic>.from(summary)
      ..removeWhere((key, value) => value == null);

    try {
      await _db
          .collection('events')
          .doc(eventId)
          .collection('presence')
          .doc(uid)
          .set({
            ...safeSummary,
            'uid': uid,
            'lastSeen': FieldValue.serverTimestamp(),
            'isActive': true,
          }, SetOptions(merge: true));

      if (sessionBleId != null) {
        final parsed = AppConstants.parseBeaconKey(sessionBleId);

        await _db
            .collection('events')
            .doc(eventId)
            .collection('bleMapping')
            .doc(sessionBleId)
            .set({
              ...safeSummary,
              'uid': uid,
              'sessionBleId': sessionBleId,
              'beaconKey': sessionBleId,
              'major': parsed.major,
              'minor': parsed.minor,
              'beaconUuid': AppConstants.proximeetBeaconUuid,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
      }

      Log.d('SESSION', 'Profilo evento aggiornato');
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'PROFILE_UPDATE',
        fallbackTitle: 'Errore aggiornamento profilo evento',
        fallbackMessage:
            'Non è stato possibile aggiornare presence/bleMapping.',
        fallbackSuggestion:
            'Controlla Firestore Rules su presence e bleMapping.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'eventId': eventId,
          'uid': uid,
          'sessionBleId': sessionBleId,
          'summary': safeSummary,
        },
      );

      rethrow;
    }
  }

  Future<void> leaveEvent() async {
    final eventId = _currentEventId;
    final sessionBleId = _sessionBleId;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    Log.d('SESSION', 'Leave evento $eventId');

    PresenceHeartbeatService.instance.stop();

    try {
      await BleAdvertiserService.shared.stop();
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'BEACON_STOP',
        fallbackTitle: 'Errore stop beacon',
        fallbackMessage: 'Errore durante lo stop del beacon.',
        fallbackSuggestion: 'Controlla PlatformBeaconService.stop().',
        error: e,
        stackTrace: st,
      );
    }

    try {
      await BleScannerService.shared.stop();
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'SCANNER_STOP',
        fallbackTitle: 'Errore stop scanner',
        fallbackMessage: 'Errore durante lo stop dello scanner.',
        fallbackSuggestion: 'Controlla BleScannerService.stop().',
        error: e,
        stackTrace: st,
      );
    }

    try {
      NearbyDetectionService.instance.clear();
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'NEARBY_CLEAR',
        fallbackTitle: 'Errore pulizia nearby',
        fallbackMessage: 'Errore durante la pulizia dello stato nearby.',
        fallbackSuggestion: 'Controlla NearbyDetectionService.clear().',
        error: e,
        stackTrace: st,
      );
    }

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

      if (sessionBleId != null) {
        try {
          await _db
              .collection('events')
              .doc(eventId)
              .collection('bleMapping')
              .doc(sessionBleId)
              .delete();
        } catch (e, st) {
          DebugErrorService.instance.fromException(
            area: 'FIRESTORE_LEAVE_BLE_MAPPING',
            fallbackTitle: 'Errore cancellazione bleMapping',
            fallbackMessage:
                'Non è stato possibile rimuovere il mapping beacon.',
            fallbackSuggestion:
                'Controlla rules Firestore su bleMapping/{beaconKey}.',
            error: e,
            stackTrace: st,
            data: <String, Object?>{
              'eventId': eventId,
              'beaconKey': sessionBleId,
            },
          );
        }
      }
    }

    _currentEventId = null;
    _sessionBleId = null;
    _isInEvent = false;

    Log.d('SESSION', 'Leave completato');
  }
}
