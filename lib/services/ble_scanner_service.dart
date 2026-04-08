import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/event_model.dart';
import '../models/nearby_user.dart';

/// Servizio di scanning BLE.
///
/// Scansiona periodicamente, filtra per il service UUID dell'app,
/// estrae il [sessionBleId] dal manufacturer data ed emette
/// [RawBleDetection] su uno stream.
class BleScannerService {
  static final BleScannerService shared = BleScannerService._();
  BleScannerService._();

  final _detectedController = StreamController<RawBleDetection>.broadcast();
  StreamSubscription? _scanResultsSub;
  Timer? _scanTimer;
  bool _isScanning = false;
  String? _mySessionBleId;

  /// Stream di detection grezze — consumato da [NearbyDetectionService].
  Stream<RawBleDetection> get detections => _detectedController.stream;
  bool get isScanning => _isScanning;

  /// Avvia scan periodico ogni [intervalSeconds].
  /// Ogni ciclo dura [scanDurationSeconds].
  Future<void> start({
    required String mySessionBleId,
    int intervalSeconds = 8,
    int scanDurationSeconds = 5,
  }) async {
    if (_isScanning) return;
    _isScanning = true;
    _mySessionBleId = mySessionBleId;

    // Ascolta risultati scan
    _scanResultsSub = FlutterBluePlus.scanResults.listen(_processScanResults);

    // Primo scan immediato
    await _doScan(scanDurationSeconds);

    // Scan periodico
    _scanTimer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => _doScan(scanDurationSeconds),
    );

    print('[BLE-SCAN] Scanning avviato (ogni ${intervalSeconds}s, durata ${scanDurationSeconds}s)');
  }

  Future<void> _doScan(int durationSeconds) async {
    try {
      // Ferma eventuale scan precedente
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }

      await FlutterBluePlus.startScan(
        withServices: [Guid(EventModel.appBleServiceUuid)],
        timeout: Duration(seconds: durationSeconds),
        continuousUpdates: true,
      );
    } catch (e) {
      print('[BLE-SCAN] Errore scan: $e');
    }
  }

  void _processScanResults(List<ScanResult> results) {
    for (final result in results) {
      final sessionBleId = _extractSessionBleId(result);
      if (sessionBleId == null) continue;
      if (sessionBleId == _mySessionBleId) continue; // ignora me stesso

      _detectedController.add(RawBleDetection(
        sessionBleId: sessionBleId,
        rssi: result.rssi,
        timestamp: DateTime.now(),
      ));
    }
  }

  /// Estrai sessionBleId dal manufacturer data del risultato scan.
  String? _extractSessionBleId(ScanResult result) {
    final mfgData = result.advertisementData.manufacturerData;
    if (mfgData.isEmpty) return null;

    // Cerca il nostro manufacturer ID (0xFF01)
    // flutter_blue_plus restituisce Map<int, List<int>>
    final data = mfgData[0xFF01] ?? mfgData.values.firstOrNull;
    if (data == null || data.isEmpty) return null;

    // Converti bytes in hex string
    return data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Ferma scanning.
  Future<void> stop() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanResultsSub?.cancel();
    _scanResultsSub = null;

    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (_) {}

    _isScanning = false;
    _mySessionBleId = null;
    print('[BLE-SCAN] Scanning fermato');
  }

  /// Chiudi definitivamente (dispose).
  void dispose() {
    stop();
    _detectedController.close();
  }
}
