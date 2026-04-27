import 'dart:async';

import 'package:flutter/services.dart';

import '../core/app_debug_error.dart';
import '../core/constants.dart';
import '../core/logger.dart';
import '../models/nearby_user.dart';
import 'debug_error_service.dart';

class PlatformBeaconService {
  PlatformBeaconService._() {
    // ── FIX iOS BEACON_START_FALSE ─────────────────────────────────────────
    // La sottoscrizione all'EventChannel viene fatta UNA SOLA VOLTA qui,
    // alla creazione del singleton.
    //
    // BUG ORIGINALE: _events.receiveBroadcastStream().listen() era chiamato
    // dentro start(), e stop() faceva cancel() su quella subscription.
    // Su iOS, ri-sottoscriversi all'EventChannel dopo un cancel lancia
    // una PlatformException silenziosa nel catch block di start(),
    // che ritornava false → BEACON_START_FALSE.
    //
    // FIX: la subscription vive per tutta la vita del singleton.
    // Non viene mai cancellata (solo in dispose()).
    // start() e stop() chiamano solo il MethodChannel nativo per
    // avviare/fermare advertising+ranging; lo stream di eventi rimane aperto.
    // ─────────────────────────────────────────────────────────────────────────
    _nativeSub = _events.receiveBroadcastStream().listen(
      _onNativeEvent,
      onError: (Object e, StackTrace st) {
        _lastError = DebugErrorService.instance.fromException(
          area: 'BEACON_NATIVE_EVENTS',
          fallbackTitle: 'Errore eventi nativi beacon',
          fallbackMessage: 'Il canale EventChannel ha restituito un errore.',
          fallbackSuggestion:
              'Controlla AppDelegate.swift / ProxiMeetBeaconPlugin.kt.',
          error: e,
          stackTrace: st,
        );
      },
    );
  }

  static final PlatformBeaconService instance = PlatformBeaconService._();

  static const MethodChannel _method = MethodChannel('proximeet/beacon');
  static const EventChannel _events = EventChannel('proximeet/beacon_events');

  final StreamController<RawBleDetection> _controller =
      StreamController<RawBleDetection>.broadcast();

  // Subscription persistente: non viene mai cancellata fuori da dispose().
  StreamSubscription<dynamic>? _nativeSub;

  bool _isRunning = false;
  String? _myBeaconKey;
  AppDebugError? _lastError;

  bool get isRunning => _isRunning;
  String? get myBeaconKey => _myBeaconKey;
  AppDebugError? get lastError => _lastError;
  Stream<RawBleDetection> get detections => _controller.stream;

  Future<bool> start(String beaconKey) async {
    _lastError = null;

    if (_isRunning && _myBeaconKey == beaconKey) return true;

    if (!AppConstants.isValidBeaconKey(beaconKey)) {
      _lastError = DebugErrorService.instance.add(AppDebugError(
        title: 'Beacon key non valida',
        area: 'BEACON_START',
        code: 'INVALID_BEACON_KEY',
        message: 'La chiave beacon deve essere nel formato 00000_00000.',
        suggestion:
            'Controlla EventSessionService._generateBeaconKey() e AppConstants.beaconKey().',
        data: <String, Object?>{'beaconKey': beaconKey},
      ));
      return false;
    }

    // Ferma il native precedente senza toccare la subscription EventChannel.
    await _stopNative();

    final parsed = AppConstants.parseBeaconKey(beaconKey);

    try {
      final ok = await _method.invokeMethod<bool>('start', <String, dynamic>{
        'uuid': AppConstants.proximeetBeaconUuid,
        'major': parsed.major,
        'minor': parsed.minor,
      });

      if (ok != true) {
        _lastError = DebugErrorService.instance.add(AppDebugError(
          title: 'Beacon non avviato',
          area: 'BEACON_START',
          code: 'NATIVE_START_RETURNED_FALSE',
          message: 'Il metodo nativo start ha risposto false/null.',
          suggestion:
              'Controlla lo stato Bluetooth e i log nativi. Il join deve continuare comunque.',
          data: <String, Object?>{
            'beaconKey': beaconKey,
            'uuid': AppConstants.proximeetBeaconUuid,
            'major': parsed.major,
            'minor': parsed.minor,
            'nativeResult': ok,
          },
        ));
        return false;
      }

      _isRunning = true;
      _myBeaconKey = beaconKey;
      Log.d('BEACON', 'Avviato beaconKey=$beaconKey');
      return true;
    } catch (e, st) {
      _lastError = DebugErrorService.instance.fromException(
        area: 'BEACON_START',
        fallbackTitle: 'Errore avvio iBeacon',
        fallbackMessage: 'Il plugin nativo non ha avviato advertising/ranging.',
        fallbackSuggestion:
            'Controlla MethodChannel proximeet/beacon, permessi e codice Swift/Kotlin.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'beaconKey': beaconKey,
          'uuid': AppConstants.proximeetBeaconUuid,
          'major': parsed.major,
          'minor': parsed.minor,
        },
      );
      return false;
    }
  }

  void _onNativeEvent(dynamic event) {
    if (event is! Map) {
      DebugErrorService.instance.add(AppDebugError(
        title: 'Evento beacon non valido',
        area: 'BEACON_NATIVE_EVENTS',
        code: 'INVALID_NATIVE_EVENT',
        message: 'Il plugin nativo ha inviato un evento non Map.',
        suggestion: 'Controlla eventSink in Swift/Kotlin.',
        data: <String, Object?>{'event': event},
      ));
      return;
    }

    final type = event['type']?.toString();
    if (type != null && type != 'beacon') {
      Log.d('BEACON', 'Native event: $event');
      return;
    }

    final major = _asInt(event['major']);
    final minor = _asInt(event['minor']);

    if (major == null || minor == null) {
      DebugErrorService.instance.add(AppDebugError(
        title: 'Evento beacon senza major/minor',
        area: 'BEACON_NATIVE_EVENTS',
        code: 'MISSING_MAJOR_MINOR',
        message:
            'Il plugin nativo ha inviato un beacon senza major/minor validi.',
        suggestion:
            'Controlla handleRangedBeacons in Swift e parseIBeacon in Kotlin.',
        data: Map<String, Object?>.from(event),
      ));
      return;
    }

    final beaconKey = AppConstants.beaconKey(major, minor);
    if (beaconKey == _myBeaconKey) return;

    final rssi = _asInt(event['rssi']) ?? -90;
    _controller.add(RawBleDetection(
      sessionBleId: beaconKey,
      rssi: rssi,
      timestamp: DateTime.now(),
    ));
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Ferma il plugin nativo senza toccare la subscription EventChannel.
  Future<void> _stopNative() async {
    try {
      await _method.invokeMethod<void>('stop');
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'BEACON_STOP',
        fallbackTitle: 'Errore stop iBeacon',
        fallbackMessage: 'Il plugin nativo non ha confermato lo stop.',
        fallbackSuggestion:
            'Di solito non è bloccante. Controlla se il plugin è registrato.',
        error: e,
        stackTrace: st,
      );
    }
    _isRunning = false;
    _myBeaconKey = null;
  }

  Future<void> stop() async {
    await _stopNative();
    Log.d('BEACON', 'Fermato');
  }

  void dispose() {
    _stopNative();
    _nativeSub?.cancel();
    _nativeSub = null;
    _controller.close();
  }
}
