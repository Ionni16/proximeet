import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../models/nearby_user.dart';
import 'ble_advertiser_service.dart';

/// BLE Scanner — singleton cross-platform (v3).
///
/// ─── Strategia di scan ───────────────────────────────────────────────────────
///
/// iOS  → SCAN CONTINUO senza filtro hardware. Un solo startScan(), dura
///        finché non chiamiamo stop(). Niente Timer.periodic.
/// Android → SCAN PERIODICO 5s/8s (workaround per chipset variabili).
///
/// Filtraggio in Dart, non hardware: con `withServices` vuoto vediamo
/// TUTTO il traffico BLE e parsiamo noi. Costa un po' di batteria in più
/// ma evita due bug noti del filtro hardware iOS:
///   - matching inaffidabile su UUID 16-bit shortened
///   - dedup cache che blocca consegne dopo restart
///
/// ─── Protocollo di parsing ───────────────────────────────────────────────────
///
/// Canale 1 (PRIMARIO) — Service UUID 128-bit dinamico:
///   Cerca un UUID che termina con la signature ProxiMeet
///   ("FAAB50524F58494D"). I primi 8 byte dell'UUID sono il sessionBleId.
///   Visibile a tutti gli scanner BLE su qualunque OS, immune a localName
///   stripping (iPad → iPhone) e a Continuity filtering.
///
/// Canale 2 (FALLBACK LEGACY) — Manufacturer Data:
///   ad.manufacturerData[0xFFFF] = 8 byte sessionBleId.
///   Mantenuto per compatibilità con device che girano una vecchia
///   versione dell'app durante eventi misti.
///
/// Canale 3 (FALLBACK LEGACY) — localName "PM-{sessionBleId}":
///   Idem, fallback per vecchie versioni.
///
/// ─────────────────────────────────────────────────────────────────────────────
class BleScannerService {
  BleScannerService._();
  static final BleScannerService instance = BleScannerService._();

  final _detectedController = StreamController<RawBleDetection>.broadcast();
  StreamSubscription<List<ScanResult>>? _scanResultsSub;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSub;
  Timer? _scanTimer;
  Timer? _statsTimer;
  bool _isScanning = false;
  String? _mySessionBleId;

  final Map<String, DateTime> _lastEmittedAt = {};
  static const Duration _emitThrottle = Duration(seconds: 3);

  // Diagnostica.
  int _totalScanResultsReceived = 0;
  int _proxiMeetSignalsReceived = 0;

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
    _lastEmittedAt.clear();
    _totalScanResultsReceived = 0;
    _proxiMeetSignalsReceived = 0;

    _adapterStateSub = FlutterBluePlus.adapterState.listen((state) {
      Log.d('BLE-SCAN', 'adapterState=$state');
      if (state == BluetoothAdapterState.unauthorized) {
        Log.e(
          'BLE-SCAN',
          'PERMESSO BLUETOOTH NEGATO. '
          'Vai in Impostazioni → ProxiMeet → Bluetooth e abilita.',
        );
      }
    });

    _scanResultsSub = FlutterBluePlus.scanResults.listen(
      _processScanResults,
      onError: (e, st) => Log.e('BLE-SCAN', 'Errore stream scanResults', e, st),
    );

    if (Platform.isIOS) {
      await _startContinuousIOS();
    } else {
      await _doAndroidScan(scanDurationSeconds);
      _scanTimer = Timer.periodic(
        Duration(seconds: intervalSeconds),
        (_) => _doAndroidScan(scanDurationSeconds),
      );
    }

    _statsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      Log.d(
        'BLE-SCAN',
        'STATS — totalResults=$_totalScanResultsReceived '
        'proxiMeetSignals=$_proxiMeetSignalsReceived '
        'isScanningNow=${FlutterBluePlus.isScanningNow}',
      );
    });

    Log.d(
      'BLE-SCAN',
      'Avviato — platform=${Platform.operatingSystem} '
      'mode=${Platform.isIOS ? "continuous" : "periodic"}',
    );
  }

  Future<void> _startContinuousIOS() async {
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(milliseconds: 500));
      }
      await FlutterBluePlus.startScan(
        withServices: const <Guid>[],
        continuousUpdates: true,
        oneByOne: true,
      );
      Log.d('BLE-SCAN', 'iOS continuous scan avviato');
    } catch (e, st) {
      Log.e('BLE-SCAN', 'Errore _startContinuousIOS', e, st);
    }
  }

  Future<void> _doAndroidScan(int durationSeconds) async {
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(milliseconds: 100));
      }
      await FlutterBluePlus.startScan(
        withServices: const <Guid>[],
        timeout: Duration(seconds: durationSeconds),
        continuousUpdates: true,
        oneByOne: true,
        androidScanMode: AndroidScanMode.lowLatency,
      );
    } catch (e, st) {
      Log.e('BLE-SCAN', 'Errore _doAndroidScan', e, st);
    }
  }

  void _processScanResults(List<ScanResult> results) {
    for (final result in results) {
      _totalScanResultsReceived++;
      if (result.rssi < -95) continue;

      final sessionBleId = _extractSessionBleId(result);
      if (sessionBleId == null) continue;

      _proxiMeetSignalsReceived++;

      if (sessionBleId == _mySessionBleId) continue;

      final now = DateTime.now();
      final lastEmit = _lastEmittedAt[sessionBleId];
      if (lastEmit != null && now.difference(lastEmit) < _emitThrottle) {
        continue;
      }
      _lastEmittedAt[sessionBleId] = now;

      _detectedController.add(
        RawBleDetection(
          sessionBleId: sessionBleId,
          rssi: result.rssi,
          timestamp: now,
        ),
      );

      Log.d(
        'BLE-SCAN',
        'Rilevato [$sessionBleId] '
        'rssi=${result.rssi} '
        'channel=${_lastChannel ?? "?"} '
        'device=${result.device.remoteId}',
      );
    }
  }

  /// Tracks da quale canale è arrivata l'ultima detection (solo per log).
  String? _lastChannel;

  /// Estrae sessionBleId provando i 3 canali in ordine di priorità.
  String? _extractSessionBleId(ScanResult result) {
    final ad = result.advertisementData;

    // ── Canale 1 (primario v2): Service UUID 128-bit dinamico ────────────────
    for (final guid in ad.serviceUuids) {
      final extracted = AppConstants.extractSessionBleIdFromUuid(guid.str);
      if (extracted != null) {
        _lastChannel = 'uuid';
        return extracted;
      }
    }

    // ── Canale 2 (legacy): manufacturer data ─────────────────────────────────
    final mfrPayload =
        ad.manufacturerData[AppConstants.legacyBleManufacturerId];
    final expectedBytes = AppConstants.sessionBleIdLength ~/ 2;
    if (mfrPayload != null && mfrPayload.length >= expectedBytes) {
      final hexId = BleAdvertiserService.bytesToHex(
        mfrPayload.take(expectedBytes).toList(),
      );
      if (_isValidBleId(hexId)) {
        _lastChannel = 'mfr';
        return hexId;
      }
    }

    // ── Canale 3 (legacy): localName "PM-..." ────────────────────────────────
    final advName = ad.advName.trim();
    if (advName.startsWith(AppConstants.legacyBleNamePrefix)) {
      final candidate = advName.substring(
        AppConstants.legacyBleNamePrefix.length,
      );
      final idLen = AppConstants.sessionBleIdLength;
      if (candidate.length >= idLen &&
          _isValidBleId(candidate.substring(0, idLen))) {
        _lastChannel = 'name';
        return candidate.substring(0, idLen);
      }
    }

    return null;
  }

  bool _isValidBleId(String id) {
    if (id.length != AppConstants.sessionBleIdLength) return false;
    return RegExp(r'^[0-9a-fA-F]+$').hasMatch(id);
  }

  Future<void> stop() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;

    await _scanResultsSub?.cancel();
    _scanResultsSub = null;
    await _adapterStateSub?.cancel();
    _adapterStateSub = null;

    _lastEmittedAt.clear();

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
