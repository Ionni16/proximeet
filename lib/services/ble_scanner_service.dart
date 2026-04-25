import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../models/nearby_user.dart';
import 'ble_advertiser_service.dart';

/// BLE Scanner — singleton cross-platform (versione no-hw-filter).
///
/// ─── Strategia di scan ───────────────────────────────────────────────────────
///
/// Sia iOS che Android: SCAN SENZA filtro `withServices`.
///
/// Motivo: il filtro hardware iOS (`withServices`) ha problemi noti di
/// matching quando l'advertisement contiene il service UUID in forma
/// 16-bit shortened (es. 0xFAAB), tipicamente quando il peer è Android
/// o quando iOS stesso ottimizza il base-UUID Bluetooth SIG. Risultato:
/// scan iOS hardware-filtrato che non riceve mai callback, anche se
/// l'advertisement è valido e visibile a scanner Android.
///
/// Workaround: niente filtro hardware, parsing in Dart (come Android).
/// Costo: ~10–15% in più di batteria su iOS in foreground.
/// Beneficio: cross-platform reliability garantita.
///
/// Per il supporto background dovremo reintrodurre `withServices` ma
/// con un secondo UUID 128-bit puramente custom (non base-UUID
/// expansion) per evitare il bug.
///
/// iOS  → un solo startScan continuo (no Timer.periodic).
/// Android → restart periodico (kept as-is, workaround chipset).
///
/// ─── Protocollo di parsing (immutato) ────────────────────────────────────────
///
/// Canale 1 — Manufacturer Data: ad.manufacturerData[0xFFFF] = 8 byte ID.
/// Canale 2 — advName: "PM-{sessionBleId}".
///
/// ─────────────────────────────────────────────────────────────────────────────
class BleScannerService {
  BleScannerService._();
  static final BleScannerService instance = BleScannerService._();

  final _detectedController = StreamController<RawBleDetection>.broadcast();
  StreamSubscription<List<ScanResult>>? _scanResultsSub;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSub;
  Timer? _scanTimer;
  bool _isScanning = false;
  String? _mySessionBleId;

  final Map<String, DateTime> _lastEmittedAt = {};
  static const Duration _emitThrottle = Duration(seconds: 3);

  /// Counter per debug — capire se lo scan riceve qualcosa.
  int _totalScanResultsReceived = 0;
  int _proxiMeetSignalsReceived = 0;
  Timer? _statsTimer;

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

    // Diagnostica: stato adapter + permission.
    // Su iOS state == unauthorized significa permission negata,
    // visualmente identico a "off" ma fix totalmente diverso.
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

    final initialState = await FlutterBluePlus.adapterState.first;
    Log.d('BLE-SCAN', 'Stato iniziale adapter: $initialState');
    if (initialState != BluetoothAdapterState.on) {
      Log.w(
        'BLE-SCAN',
        'Adapter non on (state=$initialState) — scan partirà comunque '
        'ma probabilmente fallirà.',
      );
    }

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

    // Stats periodiche per capire se lo scan è "vivo" o non riceve nulla.
    _statsTimer = Timer.periodic(const Duration(seconds: 10), (_) {
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
      'mode=${Platform.isIOS ? "continuous-no-filter" : "periodic-no-filter"}',
    );
  }

  /// iOS: scan continuo SENZA filtro hardware.
  Future<void> _startContinuousIOS() async {
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      await FlutterBluePlus.startScan(
        // NIENTE withServices: vediamo TUTTO, filtriamo in Dart.
        withServices: const <Guid>[],
        continuousUpdates: true,
        oneByOne: true,
        // No timeout = continuo.
      );

      Log.d('BLE-SCAN', 'iOS continuous scan avviato (no hw filter)');
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

      final ad = result.advertisementData;

      // Capisci se è un signal ProxiMeet anche se non riusciamo a parsarlo
      // — ci serve per stats e per log diagnostico.
      final hasProxiMeetUuid = ad.serviceUuids.any(
        (u) => u.toString().toUpperCase().contains('FAAB'),
      );
      final hasProxiMeetAdvName = ad.advName.startsWith(
        AppConstants.bleNamePrefix,
      );
      final hasProxiMeetMfr = ad.manufacturerData.containsKey(
        AppConstants.bleManufacturerId,
      );
      final isProxiMeet = hasProxiMeetUuid ||
          hasProxiMeetAdvName ||
          hasProxiMeetMfr;

      if (isProxiMeet) {
        _proxiMeetSignalsReceived++;
      }

      final sessionBleId = _extractSessionBleId(result);

      if (sessionBleId == null) {
        if (isProxiMeet) {
          _logRawAdvertisement(result, parsedId: null, label: 'PARSE_FAIL');
        }
        continue;
      }

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

      _logRawAdvertisement(result, parsedId: sessionBleId, label: 'OK');

      Log.d(
        'BLE-SCAN',
        'Rilevato [$sessionBleId] '
        'rssi=${result.rssi} '
        'device=${result.device.remoteId}',
      );
    }
  }

  String? _extractSessionBleId(ScanResult result) {
    final ad = result.advertisementData;
    const idLen = AppConstants.sessionBleIdLength;
    final expectedBytes = idLen ~/ 2;

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
