import 'dart:async';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../models/nearby_user.dart';

class PlatformBeaconService {
  PlatformBeaconService._();
  static final PlatformBeaconService instance = PlatformBeaconService._();

  static const MethodChannel _method = MethodChannel('proximeet/beacon');
  static const EventChannel _events = EventChannel('proximeet/beacon_events');

  final StreamController<RawBleDetection> _controller =
      StreamController<RawBleDetection>.broadcast();

  StreamSubscription<dynamic>? _nativeSub;
  bool _isRunning = false;
  String? _myBeaconKey;

  bool get isRunning => _isRunning;
  String? get myBeaconKey => _myBeaconKey;
  Stream<RawBleDetection> get detections => _controller.stream;

  Future<bool> start(String beaconKey) async {
    if (_isRunning && _myBeaconKey == beaconKey) return true;
    if (!AppConstants.isValidBeaconKey(beaconKey)) {
      Log.e('BEACON', 'beaconKey non valido: $beaconKey');
      return false;
    }

    await stop();
    final parsed = AppConstants.parseBeaconKey(beaconKey);

    try {
      _nativeSub = _events.receiveBroadcastStream().listen(
        _onNativeEvent,
        onError: (e, st) => Log.e('BEACON', 'Errore native event', e, st),
      );

      final ok = await _method.invokeMethod<bool>('start', <String, dynamic>{
        'uuid': AppConstants.proximeetBeaconUuid,
        'major': parsed.major,
        'minor': parsed.minor,
      });

      if (ok != true) {
        await stop();
        return false;
      }

      _isRunning = true;
      _myBeaconKey = beaconKey;
      Log.d('BEACON', 'Avviato beaconKey=$beaconKey');
      return true;
    } catch (e, st) {
      Log.e('BEACON', 'Errore start', e, st);
      await stop();
      return false;
    }
  }

  void _onNativeEvent(dynamic event) {
    if (event is! Map) return;
    final major = _asInt(event['major']);
    final minor = _asInt(event['minor']);
    if (major == null || minor == null) return;

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

  Future<void> stop() async {
    try {
      await _method.invokeMethod<void>('stop');
    } catch (_) {}
    await _nativeSub?.cancel();
    _nativeSub = null;
    _isRunning = false;
    _myBeaconKey = null;
    Log.d('BEACON', 'Fermato');
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
