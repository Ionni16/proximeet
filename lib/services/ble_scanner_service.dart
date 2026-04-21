import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../models/nearby_user.dart';

/// BLE Scanner cross-platform (Android + iOS).
///
/// Strategia robusta:
/// 1. Local name con prefix "PM-"
/// 2. platformName con prefix "PM-" come fallback
///
/// Non usiamo più manufacturer/service UUID come canale principale,
/// perché il payload advertising deve restare minimale e simmetrico.
class BleScannerService {
  BleScannerService._();
  static final BleScannerService instance = BleScannerService._();

  final _detectedController = StreamController<RawBleDetection>.broadcast();
  StreamSubscription<List<ScanResult>>? _scanResultsSub;
  Timer? _scanTimer;
  bool _isScanning = false;
  String? _mySessionBleId;
  final Set<String> _seenThisCycle = {};

  Stream<RawBleDetection> get detections => _detectedController.stream;
  bool get isScanning => _isScanning;

  Future<void> start({
    required String mySessionBleId,
    int intervalSeconds = AppConstants.scanIntervalSeconds,
    int scanDurationSeconds = AppConstants.scanDurationSeconds,
  }) async {
    if (_isScanning) return;

    _isScanning = true;
    _mySessionBleId = mySessionBleId;

    _scanResultsSub = FlutterBluePlus.scanResults.listen(
      _processScanResults,
      onError: (e) => Log.e('BLE-SCAN', 'Errore stream scanResults', e),
    );

    await _doScan(scanDurationSeconds);

    _scanTimer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => _doScan(scanDurationSeconds),
    );

    Log.d(
      'BLE-SCAN',
      'Avviato (ogni ${intervalSeconds}s, durata ${scanDurationSeconds}s)',
    );
  }

  Future<void> _doScan(int durationSeconds) async {
    try {
      _seenThisCycle.clear();

      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }

      await FlutterBluePlus.startScan(
        timeout: Duration(seconds: durationSeconds),
        continuousUpdates: true,
        androidScanMode: AndroidScanMode.lowLatency,
      );
    } catch (e) {
      Log.e('BLE-SCAN', 'Errore scan', e);
    }
  }

  void _processScanResults(List<ScanResult> results) {
    for (final result in results) {
      final sessionBleId = _extractSessionBleId(result);

      if (sessionBleId == null) {
        _logRawAdvertisement(result, parsedId: null);
        continue;
      }

      if (sessionBleId == _mySessionBleId) continue;
      if (_seenThisCycle.contains(sessionBleId)) continue;

      _seenThisCycle.add(sessionBleId);

      _detectedController.add(
        RawBleDetection(
          sessionBleId: sessionBleId,
          rssi: result.rssi,
          timestamp: DateTime.now(),
        ),
      );

      _logRawAdvertisement(result, parsedId: sessionBleId);

      Log.d(
        'BLE-SCAN',
        'Rilevato: $sessionBleId RSSI=${result.rssi} device=${result.device.platformName}',
      );
    }
  }

  String? _extractSessionBleId(ScanResult result) {
    final ad = result.advertisementData;
    const prefix = AppConstants.bleNamePrefix;
    const idLen = AppConstants.sessionBleIdLength;
    final minNameLen = prefix.length + idLen;

    final advName = ad.advName.trim();
    if (advName.startsWith(prefix) && advName.length >= minNameLen) {
      return advName.substring(prefix.length, prefix.length + idLen);
    }

    final platformName = result.device.platformName.trim();
    if (platformName.startsWith(prefix) && platformName.length >= minNameLen) {
      return platformName.substring(prefix.length, prefix.length + idLen);
    }

    return null;
  }

  void _logRawAdvertisement(ScanResult result, {required String? parsedId}) {
    final ad = result.advertisementData;

    Log.d(
      'BLE-SCAN-RAW',
      'parsedId=$parsedId '
      'advName="${ad.advName}" '
      'platformName="${result.device.platformName}" '
      'serviceUuids=${ad.serviceUuids.map((e) => e.toString()).toList()} '
      'manufacturerKeys=${ad.manufacturerData.keys.toList()} '
      'serviceDataKeys=${ad.serviceData.keys.map((e) => e.toString()).toList()} '
      'rssi=${result.rssi}',
    );
  }

  Future<void> stop() async {
    _scanTimer?.cancel();
    _scanTimer = null;

    await _scanResultsSub?.cancel();
    _scanResultsSub = null;

    _seenThisCycle.clear();

    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (_) {}

    _isScanning = false;
    _mySessionBleId = null;
    Log.d('BLE-SCAN', 'Fermato');
  }

  void dispose() {
    stop();
    _detectedController.close();
  }
}