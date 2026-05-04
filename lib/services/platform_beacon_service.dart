import 'dart:async';

import 'package:flutter/services.dart';

import '../core/app_debug_error.dart';
import '../core/constants.dart';
import '../core/logger.dart';
import '../models/nearby_user.dart';
import 'debug_error_service.dart';

/// Parla con il codice nativo (Swift/Kotlin) tramite MethodChannel e EventChannel.
///
/// Ogni telefono fa due cose contemporaneamente: espone un server GATT
/// con il proprio token temporaneo e scansiona i GATT dei peer vicini.
///
/// Il canale si chiama ancora "proximeet/beacon" per retrocompatibilità,
/// ma ora usa BLE GATT, non iBeacon.
class PlatformBeaconService {
  PlatformBeaconService._() {
    _nativeSub = _events.receiveBroadcastStream().listen(
      _onNativeEvent,
      onError: (Object e, StackTrace st) {
        _lastError = DebugErrorService.instance.fromException(
          area: 'BLE_GATT_NATIVE_EVENTS',
          fallbackTitle: 'Errore eventi nativi BLE GATT',
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

  StreamSubscription<dynamic>? _nativeSub;

  bool _isRunning = false;
  String? _myToken;
  AppDebugError? _lastError;

  bool get isRunning => _isRunning;
  String? get myBeaconKey => _myToken;
  String? get myToken => _myToken;
  AppDebugError? get lastError => _lastError;
  Stream<RawBleDetection> get detections => _controller.stream;

  Future<bool> start(String token) async {
    _lastError = null;

    if (_isRunning && _myToken == token) return true;

    if (!AppConstants.isValidProximityToken(token)) {
      _lastError = DebugErrorService.instance.add(AppDebugError(
        title: 'Token BLE non valido',
        area: 'BLE_GATT_START',
        code: 'INVALID_PROXIMITY_TOKEN',
        message: 'Il token BLE temporaneo non è valido.',
        suggestion: 'Controlla EventSessionService._generateEphemeralToken().',
        data: <String, Object?>{'tokenLength': token.length},
      ));
      return false;
    }

    await _stopNative();

    try {
      final ok = await _method.invokeMethod<bool>('start', <String, dynamic>{
        'serviceUuid': AppConstants.proximeetGattServiceUuid,
        'tokenCharacteristicUuid': AppConstants.proximeetGattTokenCharacteristicUuid,
        'token': token,
        'transport': 'ble_gatt',
      });

      if (ok != true) {
        _lastError = DebugErrorService.instance.add(AppDebugError(
          title: 'BLE GATT non avviato',
          area: 'BLE_GATT_START',
          code: 'NATIVE_START_RETURNED_FALSE',
          message: 'Il metodo nativo start ha risposto false/null.',
          suggestion:
              'Controlla Bluetooth, permessi Nearby Devices/Localizzazione e log nativi.',
          data: <String, Object?>{
            'tokenLength': token.length,
            'serviceUuid': AppConstants.proximeetGattServiceUuid,
            'characteristicUuid': AppConstants.proximeetGattTokenCharacteristicUuid,
          },
        ));
        return false;
      }

      _isRunning = true;
      _myToken = token;
      Log.d('BLE_GATT', 'Avviato token=${_redact(token)}');
      return true;
    } catch (e, st) {
      _lastError = DebugErrorService.instance.fromException(
        area: 'BLE_GATT_START',
        fallbackTitle: 'Errore avvio BLE GATT',
        fallbackMessage:
            'Il plugin nativo non ha avviato advertising/scanning GATT.',
        fallbackSuggestion:
            'Controlla MethodChannel proximeet/beacon, permessi e codice Swift/Kotlin.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'tokenLength': token.length,
          'serviceUuid': AppConstants.proximeetGattServiceUuid,
        },
      );
      return false;
    }
  }

  void _onNativeEvent(dynamic event) {
    if (event is! Map) {
      DebugErrorService.instance.add(AppDebugError(
        title: 'Evento BLE non valido',
        area: 'BLE_GATT_NATIVE_EVENTS',
        code: 'INVALID_NATIVE_EVENT',
        message: 'Il plugin nativo ha inviato un evento non Map.',
        suggestion: 'Controlla eventSink in Swift/Kotlin.',
        data: <String, Object?>{'event': event},
      ));
      return;
    }

    final type = event['type']?.toString();
    if (type != null && type != 'gattPeer' && type != 'beacon') {
      Log.d('BLE_GATT', 'Native event: $event');
      return;
    }

    final token = (event['token'] ?? event['sessionBleId'] ?? event['beaconKey'])
        ?.toString()
        .trim();

    if (token == null || token.isEmpty) {
      DebugErrorService.instance.add(AppDebugError(
        title: 'Evento BLE senza token',
        area: 'BLE_GATT_NATIVE_EVENTS',
        code: 'MISSING_TOKEN',
        message: 'Il plugin nativo ha inviato una detection senza token.',
        suggestion: 'Controlla lettura characteristic GATT nel plugin nativo.',
        data: Map<String, Object?>.from(event),
      ));
      return;
    }

    if (token == _myToken) return;

    final rssi = _asInt(event['rssi']) ?? -90;
    _controller.add(RawBleDetection(
      sessionBleId: token,
      rssi: rssi,
      timestamp: DateTime.now(),
      transport: event['transport']?.toString() ?? 'ble_gatt',
    ));
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  Future<void> _stopNative() async {
    try {
      await _method.invokeMethod<void>('stop');
    } catch (e, st) {
      DebugErrorService.instance.fromException(
        area: 'BLE_GATT_STOP',
        fallbackTitle: 'Errore stop BLE GATT',
        fallbackMessage: 'Il plugin nativo non ha confermato lo stop.',
        fallbackSuggestion: 'Di solito non è bloccante. Controlla i log nativi.',
        error: e,
        stackTrace: st,
      );
    }
    _isRunning = false;
    _myToken = null;
  }

  Future<void> stop() async {
    await _stopNative();
    Log.d('BLE_GATT', 'Fermato');
  }

  Future<void> dispose() async {
    await _nativeSub?.cancel();
    _nativeSub = null;
    await _stopNative();
  }

  String _redact(String value) {
    if (value.length <= 10) return '***';
    return '${value.substring(0, 6)}…${value.substring(value.length - 4)}';
  }
}
