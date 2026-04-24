import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../models/nearby_user.dart';
import 'ble_advertiser_service.dart';

/// BLE Scanner — singleton cross-platform.
///
/// ─── Protocollo di parsing ───────────────────────────────────────────────────
///
/// Il parser prova due canali in ordine di priorità, senza dipendere da
/// platformName (che è cache di sistema, non dati live dal pacchetto BLE).
///
/// Priorità 1 — Manufacturer Data  →  rileva Android da qualsiasi platform
///   flutter_blue_plus espone ad.manufacturerData come Map<int, List<int>>:
///     chiave  = company ID (int, 16-bit)
///     valore  = payload bytes (i byte DOPO il company ID)
///
///   Android ha advertised:
///     manufacturerId = AppConstants.bleManufacturerId (0xFFFF)
///     manufacturerData = 8 byte del sessionBleId
///
///   Quindi: ad.manufacturerData[0xFFFF] == List<int> di 8 byte → hex 16 chars.
///
/// Priorità 2 — advName con prefisso "PM-"  →  rileva iOS da qualsiasi platform
///   iOS in foreground include localName "PM-{sessionBleId}" nel main packet.
///   In background iOS non include il localName: questo caso non è rilevabile
///   tramite advName, ma è un limite di piattaforma accettato nel design.
///
/// ─── Filtro scan ─────────────────────────────────────────────────────────────
///
/// iOS: withServices:[bleServiceUuid] OBBLIGATORIO.
///   Senza filtro Core Bluetooth applica throttling aggressivo sulle scan
///   callback e NON funziona in background. Con filtro lo scan è hardware-
///   assisted e affidabile.
///   Rischio di perdere device: zero, perché tutti i device ProxiMeet
///   advertisano bleServiceUuid.
///
/// Android: nessun filtro per serviceUuid.
///   Alcuni chipset Android con filtro hardware droppano i primissimi
///   risultati durante il warmup dello scanner. Meglio ricevere tutto
///   e filtrare in Dart.
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

  // Per ciclo di scan: evita duplicati nello stesso finestra temporale.
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
      onError: (e, st) => Log.e('BLE-SCAN', 'Errore stream scanResults', e, st),
    );

    await _doScan(scanDurationSeconds);

    _scanTimer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => _doScan(scanDurationSeconds),
    );

    Log.d(
      'BLE-SCAN',
      'Avviato — platform=${Platform.operatingSystem} '
      'ciclo=${intervalSeconds}s scan=${scanDurationSeconds}s '
      'filtroUUID=${Platform.isIOS}',
    );
  }

  Future<void> _doScan(int durationSeconds) async {
    try {
      _seenThisCycle.clear();

      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
        // Breve pausa per consentire al BLE stack di resettare lo stato.
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // iOS: filtra per serviceUuid → scan affidabile + background support.
      // Android: nessun filtro → evita problemi di warmup su chipset variabili.
      final serviceFilter = Platform.isIOS
          ? [Guid(AppConstants.bleServiceUuid)]
          : <Guid>[];

      await FlutterBluePlus.startScan(
        withServices: serviceFilter,
        timeout: Duration(seconds: durationSeconds),
        continuousUpdates: true,
        androidScanMode: AndroidScanMode.lowLatency,
      );
    } catch (e, st) {
      Log.e('BLE-SCAN', 'Errore _doScan', e, st);
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
      if (_seenThisCycle.contains(sessionBleId)) continue;

      _seenThisCycle.add(sessionBleId);

      _detectedController.add(
        RawBleDetection(
          sessionBleId: sessionBleId,
          rssi: result.rssi,
          timestamp: DateTime.now(),
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
  ///
  /// Canale 1 — manufacturerData (Android → iOS/Android):
  ///   ad.manufacturerData è Map<int, List<int>> dove:
  ///     int key   = company ID (0xFFFF per ProxiMeet)
  ///     List<int> = payload bytes (NON include il company ID)
  ///   Il sessionBleId è codificato come 8 byte → li convertiamo in hex 16 chars.
  ///
  /// Canale 2 — advName (iOS foreground → Android/iOS):
  ///   advName deve iniziare con bleNamePrefix e avere la lunghezza attesa.
  ///   Non usiamo platformName: è cache di sistema e non riflette dati live.
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
        Log.d('BLE-SCAN', 'ID estratto da manufacturerData: $hexId');
        return hexId;
      }
      Log.w('BLE-SCAN', 'manufacturerData presente ma ID non valido: $hexId');
    }

    // ── Canale 2: advName ─────────────────────────────────────────────────────
    final advName = ad.advName.trim();
    if (advName.startsWith(AppConstants.bleNamePrefix)) {
      final candidate = advName.substring(AppConstants.bleNamePrefix.length);
      if (candidate.length >= idLen && _isValidBleId(candidate.substring(0, idLen))) {
        Log.d('BLE-SCAN', 'ID estratto da advName: ${candidate.substring(0, idLen)}');
        return candidate.substring(0, idLen);
      }
    }

    // Nessun canale valido.
    return null;
  }

  /// Verifica che la stringa sia un hex valido della lunghezza attesa.
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
