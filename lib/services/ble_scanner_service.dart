import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../models/nearby_user.dart';
import 'ble_advertiser_service.dart';

/// BLE Scanner — singleton cross-platform.
///
/// ─── Strategia di scan per piattaforma ───────────────────────────────────────
///
/// iOS  → SCAN CONTINUO (un solo startScan, mai restart in foreground).
///   Motivo: con `withServices:[uuid]` Core Bluetooth attiva il filtro
///   hardware del coprocessore BLE. Ogni stopScan/startScan rigenera lo
///   stato del filtro con warm-up di 500ms–1s. In quella finestra gli
///   advertisement vengono persi, e la cache di deduplicazione del filtro
///   nel frattempo blocca le successive consegne. Risultato pratico:
///   "iPhone non rileva niente". La fix è non spegnere mai lo scan.
///   `continuousUpdates: true` (= allowDuplicates) consegna ogni adv ricevuto.
///
/// Android → SCAN PERIODICO (8s ciclo, 5s scan).
///   Su Android il filtro non è in `withServices` (lo facciamo in Dart),
///   quindi non c'è warm-up hardware. Il restart periodico serve a
///   forzare un refresh dell'RSSI e ad aggirare bug di alcuni chipset
///   che droppano i primissimi risultati.
///
/// ─── Protocollo di parsing (immutato) ────────────────────────────────────────
///
/// Canale 1 — Manufacturer Data (Android peripheral):
///   ad.manufacturerData[0xFFFF] = 8 byte del sessionBleId.
///
/// Canale 2 — advName con prefisso "PM-" (iOS peripheral foreground):
///   advName == "PM-{sessionBleId}".
///   In iOS background il localName viene strippato dall'OS — limite
///   accettato by design (si gestirà con presence Firestore).
///
/// ─────────────────────────────────────────────────────────────────────────────
class BleScannerService {
  BleScannerService._();
  static final BleScannerService instance = BleScannerService._();

  final _detectedController = StreamController<RawBleDetection>.broadcast();
  StreamSubscription<List<ScanResult>>? _scanResultsSub;
  Timer? _scanTimer;
  bool _isScanning = false;
  String? _mySessionBleId;

  /// Tracking per-device (NON per-cycle) dell'ultima emissione.
  /// Permette di throttlare le emit senza bloccare totalmente i device
  /// già visti — fondamentale per aggiornare RSSI nel tempo.
  final Map<String, DateTime> _lastEmittedAt = {};

  /// Throttle minimo tra due emit dello stesso bleId.
  /// Evita di intasare il NearbyDetectionService con detection identiche.
  static const Duration _emitThrottle = Duration(seconds: 3);

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

    _scanResultsSub = FlutterBluePlus.scanResults.listen(
      _processScanResults,
      onError: (e, st) => Log.e('BLE-SCAN', 'Errore stream scanResults', e, st),
    );

    if (Platform.isIOS) {
      // iOS: scan continuo, niente Timer.periodic.
      await _startContinuousIOS();
    } else {
      // Android: scan periodico.
      await _doAndroidScan(scanDurationSeconds);
      _scanTimer = Timer.periodic(
        Duration(seconds: intervalSeconds),
        (_) => _doAndroidScan(scanDurationSeconds),
      );
    }

    Log.d(
      'BLE-SCAN',
      'Avviato — platform=${Platform.operatingSystem} '
      'mode=${Platform.isIOS ? "continuous" : "periodic ${intervalSeconds}s/${scanDurationSeconds}s"}',
    );
  }

  /// iOS: un solo startScan che vive finché non chiamiamo stop().
  ///
  /// Parametri critici:
  ///   withServices: [bleServiceUuid]  → OBBLIGATORIO per scan affidabile
  ///                                     e per supporto background futuro.
  ///   continuousUpdates: true         → allowDuplicates: true. Riceviamo
  ///                                     ogni adv anche da device già visti,
  ///                                     necessario per aggiornare RSSI.
  ///   oneByOne: true                  → ogni adv consegnato singolarmente
  ///                                     allo stream. No batching, no staleness.
  ///   timeout: nessuno                → scan continuo. Power management
  ///                                     gestito dall'OS.
  Future<void> _startContinuousIOS() async {
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
        // 500ms invece di 100ms: lasciamo che Core Bluetooth resetti
        // davvero il filtro hardware prima del nuovo start.
        await Future.delayed(const Duration(milliseconds: 500));
      }

      await FlutterBluePlus.startScan(
        withServices: [Guid(AppConstants.bleServiceUuid)],
        continuousUpdates: true,
        oneByOne: true,
        // No timeout = continuo.
      );

      Log.d('BLE-SCAN', 'iOS continuous scan avviato');
    } catch (e, st) {
      Log.e('BLE-SCAN', 'Errore _startContinuousIOS', e, st);
    }
  }

  /// Android: scan periodico con restart per refresh.
  Future<void> _doAndroidScan(int durationSeconds) async {
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(milliseconds: 100));
      }

      await FlutterBluePlus.startScan(
        // Android: niente filtro UUID (workaround chipset variabili).
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
      // Filtra device con RSSI troppo basso (rumore radio).
      if (result.rssi < -95) continue;

      final sessionBleId = _extractSessionBleId(result);

      if (sessionBleId == null) {
        // Log solo se c'era qualcosa di parzialmente riconoscibile,
        // per non inondare il log con device BLE estranei.
        final ad = result.advertisementData;
        final hasProxiMeetSignal = ad.serviceUuids.any(
          (u) => u.toString().toUpperCase().contains('FAAB'),
        );
        if (hasProxiMeetSignal) {
          _logRawAdvertisement(result, parsedId: null, label: 'PARSE_FAIL');
        }
        continue;
      }

      if (sessionBleId == _mySessionBleId) continue;

      // Throttle per-device (NON cycle-based).
      // Permette refresh continui ma limita la frequenza a 1 ogni _emitThrottle.
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

      _logRawAdvertisement(result, parsedId: sessionBleId, label: 'OK');

      Log.d(
        'BLE-SCAN',
        'Rilevato [$sessionBleId] '
        'rssi=${result.rssi} '
        'device=${result.device.remoteId}',
      );
    }
  }

  /// Estrae il sessionBleId dal pacchetto BLE.
  String? _extractSessionBleId(ScanResult result) {
    final ad = result.advertisementData;
    const idLen = AppConstants.sessionBleIdLength;
    final expectedBytes = idLen ~/ 2; // 8 byte

    // ── Canale 1: manufacturer data ──────────────────────────────────────────
    final mfrPayload = ad.manufacturerData[AppConstants.bleManufacturerId];
    if (mfrPayload != null && mfrPayload.length >= expectedBytes) {
      final hexId = BleAdvertiserService.bytesToHex(
        mfrPayload.take(expectedBytes).toList(),
      );
      if (_isValidBleId(hexId)) {
        return hexId;
      }
      Log.w('BLE-SCAN', 'manufacturerData presente ma ID non valido: $hexId');
    }

    // ── Canale 2: advName ─────────────────────────────────────────────────────
    final advName = ad.advName.trim();
    if (advName.startsWith(AppConstants.bleNamePrefix)) {
      final candidate = advName.substring(AppConstants.bleNamePrefix.length);
      if (candidate.length >= idLen &&
          _isValidBleId(candidate.substring(0, idLen))) {
        return candidate.substring(0, idLen);
      }
    }

    return null;
  }

  bool _isValidBleId(String id) {
    if (id.length != AppConstants.sessionBleIdLength) return false;
    return RegExp(r'^[0-9a-fA-F]+$').hasMatch(id);
  }

  void _logRawAdvertisement(
    ScanResult result, {
    required String? parsedId,
    required String label,
  }) {
    final ad = result.advertisementData;
    Log.d(
      'BLE-SCAN-RAW',
      '[$label] parsedId=$parsedId '
      'rssi=${result.rssi} '
      'advName="${ad.advName}" '
      'serviceUuids=${ad.serviceUuids.map((e) => e.str).toList()} '
      'mfrKeys=${ad.manufacturerData.keys.toList()} '
      'mfrLens=${ad.manufacturerData.values.map((v) => v.length).toList()}',
    );
  }

  Future<void> stop() async {
    _scanTimer?.cancel();
    _scanTimer = null;

    await _scanResultsSub?.cancel();
    _scanResultsSub = null;

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
