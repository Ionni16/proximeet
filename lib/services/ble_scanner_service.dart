import 'dart:async';

import '../core/logger.dart';
import '../models/nearby_user.dart';
import 'platform_beacon_service.dart';

class BleScannerService {
  BleScannerService._();
  static final BleScannerService instance = BleScannerService._();

  final StreamController<RawBleDetection> _detectedController =
      StreamController<RawBleDetection>.broadcast();

  StreamSubscription<RawBleDetection>? _sub;
  bool _isScanning = false;
  String? _mySessionBleId;
  final Map<String, DateTime> _lastEmittedAt = {};
  static const Duration _emitThrottle = Duration(seconds: 3);

  Stream<RawBleDetection> get detections => _detectedController.stream;
  bool get isScanning => _isScanning;

  Future<void> start({
    required String mySessionBleId,
    int intervalSeconds = 8,
    int scanDurationSeconds = 5,
  }) async {
    if (_isScanning && _mySessionBleId == mySessionBleId) return;
    await stop();
    _mySessionBleId = mySessionBleId;
    _isScanning = true;
    _lastEmittedAt.clear();
    _sub = PlatformBeaconService.instance.detections.listen(
      _onDetection,
      onError: (e, st) => Log.e('BLE-SCAN', 'Errore stream beacon', e, st),
    );
    Log.d('BLE-SCAN', 'Avviato su iBeacon beaconKey=$mySessionBleId');
  }

  void _onDetection(RawBleDetection raw) {
    if (raw.sessionBleId == _mySessionBleId) return;
    final now = DateTime.now();
    final lastEmit = _lastEmittedAt[raw.sessionBleId];
    if (lastEmit != null && now.difference(lastEmit) < _emitThrottle) return;
    _lastEmittedAt[raw.sessionBleId] = now;
    _detectedController.add(raw);
    Log.d('BLE-SCAN', 'Rilevato beaconKey=${raw.sessionBleId} rssi=${raw.rssi}');
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _lastEmittedAt.clear();
    _isScanning = false;
    _mySessionBleId = null;
    Log.d('BLE-SCAN', 'Fermato');
  }

  void dispose() {
    stop();
    _detectedController.close();
  }
}
