import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../models/nearby_user.dart';

/// BLE Scanner cross-platform (Android + iOS).
///
/// Estrae il sessionBleId da multiple sorgenti:
/// 1. Manufacturer data (0xFF01) — Android→Android
/// 2. Local name con prefix "PM-" — cross-platform
///
/// Singleton: usa [BleScannerService.instance].
class BleScannerService {
  BleScannerService._();
  static final BleScannerService instance = BleScannerService._();

  final _detectedController = StreamController<RawBleDetection>.broadcast();
  StreamSubscription? _scanResultsSub;
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

    _scanResultsSub = FlutterBluePlus.scanResults.listen(_processScanResults);

    await _doScan(scanDurationSeconds);

    _scanTimer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => _doScan(scanDurationSeconds),
    );

    Log.d('BLE-SCAN', 'Avviato (ogni ${intervalSeconds}s, durata ${scanDurationSeconds}s)');
  }

  Future<void> _doScan(int durationSeconds) async {
    try {
      _seenThisCycle.clear();

      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }

      // IMPORTANTE: NESSUN filtro withServices.
      // Su iOS il filtro perde i dispositivi Android che mettono il
      // serviceUUID nello scan response (pacchetto primario pieno).
      // Filtriamo noi via prefix "PM-" in _extractSessionBleId.
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
      if (sessionBleId == null) continue;
      if (sessionBleId == _mySessionBleId) continue;
      if (_seenThisCycle.contains(sessionBleId)) continue;

      _seenThisCycle.add(sessionBleId);

      _detectedController.add(RawBleDetection(
        sessionBleId: sessionBleId,
        rssi: result.rssi,
        timestamp: DateTime.now(),
      ));

      Log.d('BLE-SCAN',
          'Rilevato: $sessionBleId RSSI=${result.rssi} device=${result.device.platformName}');
    }
  }

  /// Estrai sessionBleId dal pacchetto BLE.
  ///
  /// Ordine di priorità:
  /// 1. Manufacturer data con key 0xFF01
  /// 2. Qualsiasi manufacturer data
  /// 3. Local name con prefix "PM-"
  /// 4. platformName con prefix "PM-"
  String? _extractSessionBleId(ScanResult result) {
    final ad = result.advertisementData;
    const prefix = AppConstants.bleNamePrefix;
    const idLen = AppConstants.sessionBleIdLength;
    final minNameLen = prefix.length + idLen;

    // Strategia 1: Manufacturer data
    if (ad.manufacturerData.isNotEmpty) {
      final data = ad.manufacturerData[AppConstants.bleManufacturerId];
      if (data != null && data.length >= 8) {
        final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        if (hex.length >= idLen) return hex.substring(0, idLen);
      }

      for (final entry in ad.manufacturerData.entries) {
        if (entry.value.length >= 8) {
          final hex =
              entry.value.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
          if (hex.length >= idLen) return hex.substring(0, idLen);
        }
      }
    }

    // Strategia 2: Local name
    final localName = ad.advName;
    if (localName.startsWith(prefix) && localName.length >= minNameLen) {
      return localName.substring(prefix.length, prefix.length + idLen);
    }

    // Strategia 3: platformName
    final platformName = result.device.platformName;
    if (platformName.startsWith(prefix) && platformName.length >= minNameLen) {
      return platformName.substring(prefix.length, prefix.length + idLen);
    }

    return null;
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
