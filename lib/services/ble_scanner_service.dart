import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/event_model.dart';
import '../models/nearby_user.dart';

/// BLE Scanner cross-platform (Android + iOS).
///
/// Estrae il sessionBleId da MULTIPLE sorgenti nel pacchetto advertisement,
/// per gestire le differenze Android/iOS:
///
/// 1. **Manufacturer data** (key 0xFF01) — funziona Android→Android
/// 2. **Local name** con prefix "PM-" — funziona cross-platform
///
/// Su iOS→iOS e iOS→Android il local name è l'unico modo affidabile
/// perché iOS non include manufacturer data nel suo advertising.
class BleScannerService {
  static final BleScannerService shared = BleScannerService._();
  BleScannerService._();

  final _detectedController = StreamController<RawBleDetection>.broadcast();
  StreamSubscription? _scanResultsSub;
  Timer? _scanTimer;
  bool _isScanning = false;
  String? _mySessionBleId;

  /// Set di sessionBleId già emessi in questo ciclo di scan,
  /// per evitare duplicati nello stesso batch.
  final Set<String> _seenThisCycle = {};

  Stream<RawBleDetection> get detections => _detectedController.stream;
  bool get isScanning => _isScanning;

  Future<void> start({
    required String mySessionBleId,
    int intervalSeconds = 8,
    int scanDurationSeconds = 5,
  }) async {
    if (_isScanning) return;
    _isScanning = true;
    _mySessionBleId = mySessionBleId;

    _scanResultsSub = FlutterBluePlus.scanResults.listen(_processScanResults);

    // Primo scan immediato
    await _doScan(scanDurationSeconds);

    // Scan periodico
    _scanTimer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => _doScan(scanDurationSeconds),
    );

    print('[BLE-SCAN] Avviato (ogni ${intervalSeconds}s, durata ${scanDurationSeconds}s)');
  }

  Future<void> _doScan(int durationSeconds) async {
    try {
      _seenThisCycle.clear();

      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }

      // withServices filtra per il nostro UUID — così vediamo solo ProxiMeet.
      // NOTA: su iOS in background, il service UUID nell'advertising viene
      // spostato in un "overflow area" e il filtro potrebbe non matchare.
      // Per il MVP foreground-only questo è ok.
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
      if (sessionBleId == _mySessionBleId) continue;
      if (_seenThisCycle.contains(sessionBleId)) continue;

      _seenThisCycle.add(sessionBleId);

      _detectedController.add(RawBleDetection(
        sessionBleId: sessionBleId,
        rssi: result.rssi,
        timestamp: DateTime.now(),
      ));

      print('[BLE-SCAN] Rilevato: $sessionBleId RSSI=${result.rssi} '
          'device=${result.device.platformName}');
    }
  }

  /// Estrai sessionBleId dal pacchetto BLE.
  ///
  /// Ordine di priorità:
  /// 1. Manufacturer data con key 0xFF01 (Android→Android, più affidabile)
  /// 2. Qualsiasi manufacturer data presente (fallback)
  /// 3. Local name con prefix "PM-" (cross-platform, iOS→qualsiasi)
  /// 4. advName / platformName con prefix "PM-" (ulteriore fallback)
  String? _extractSessionBleId(ScanResult result) {
    final ad = result.advertisementData;

    // ── STRATEGIA 1: Manufacturer data (Android→Android) ──
    if (ad.manufacturerData.isNotEmpty) {
      // Cerca il nostro ID specifico
      final data = ad.manufacturerData[0xFF01];
      if (data != null && data.length >= 8) {
        final hex = data
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        if (hex.length >= 16) return hex.substring(0, 16);
      }

      // Fallback: primo manufacturer data disponibile
      for (final entry in ad.manufacturerData.entries) {
        if (entry.value.length >= 8) {
          final hex = entry.value
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          if (hex.length >= 16) return hex.substring(0, 16);
        }
      }
    }

    // ── STRATEGIA 2: Local name con prefix "PM-" (iOS→qualsiasi) ──
    final localName = ad.advName;
    if (localName.startsWith('PM-') && localName.length >= 19) {
      // "PM-" (3 chars) + sessionBleId (16 chars) = 19
      return localName.substring(3, 19);
    }

    // ── STRATEGIA 3: platformName fallback ──
    final platformName = result.device.platformName;
    if (platformName.startsWith('PM-') && platformName.length >= 19) {
      return platformName.substring(3, 19);
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
    print('[BLE-SCAN] Fermato');
  }

  void dispose() {
    stop();
    _detectedController.close();
  }
}
