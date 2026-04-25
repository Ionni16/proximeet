import 'dart:typed_data';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

import '../core/constants.dart';
import '../core/logger.dart';

/// BLE Advertising — singleton cross-platform.
///
/// ─── Protocollo (v2) ─────────────────────────────────────────────────────────
///
/// L'identità ProxiMeet viaggia dentro un Service UUID 128-bit dinamico
/// costruito a partire dal sessionBleId. Schema:
///
///   XXXXXXXX-XXXX-XXXX-FAAB-50524F58494D
///   └── 8 byte sessionBleId ──┘└── 8 byte signature ──┘
///
/// Esempio: sessionBleId "669f6d6c543a4c22"
///       →  UUID "669f6d6c-543a-4c22-faab-50524f58494d"
///
/// ─── Perché UUID 128-bit invece di localName/manufacturerData ────────────────
///
/// Il Service UUID 128-bit va SEMPRE nel main advertising packet ed è
/// visibile a tutti gli scanner BLE su qualunque OS. NON è soggetto a:
///   - localName stripping (iPad → iPhone, Continuity filtering, background)
///   - manufacturerData filtering (alcune policy iOS)
///   - scan response cache miss
///
/// Costo: 18 byte nel packet (1 length + 1 type + 16 UUID), che insieme ai
/// 3 byte di FLAGS portano il payload a 21/31 byte. Restano 10 byte liberi
/// — non sufficienti né per manufacturerData (12B minimi) né per localName
/// "PM-..." (21B). Quindi questi due canali sono RIMOSSI dall'advertiser.
///
/// Per backward compatibility lo scanner continua a parsarli come fallback
/// (vedi BleScannerService).
///
/// ─── Background iOS ─────────────────────────────────────────────────────────
///
/// In background iOS è noto che CBPeripheralManager continua ad advertise
/// solo lo Service UUID (e non localName/manufacturerData). Il nostro nuovo
/// protocollo si basa proprio su quello → la rilevazione background
/// dovrebbe funzionare anche lato iOS, a patto che il peer sia in scan
/// attivo. Resta il limite duro Apple del background-to-background tra
/// device iOS che usano l'overflow area, ma quello lo gestiamo con il
/// PresenceService Firestore.
///
/// ─────────────────────────────────────────────────────────────────────────────
class BleAdvertiserService {
  BleAdvertiserService._();
  static final BleAdvertiserService instance = BleAdvertiserService._();

  final _peripheral = FlutterBlePeripheral();
  bool _isAdvertising = false;
  String? _currentSessionBleId;

  bool get isAdvertising => _isAdvertising;
  String? get currentSessionBleId => _currentSessionBleId;

  Future<bool> start(String sessionBleId) async {
    if (_isAdvertising) {
      Log.w('BLE-ADV', 'Già in advertising, ignoro start()');
      return true;
    }

    assert(
      sessionBleId.length == AppConstants.sessionBleIdLength,
      'sessionBleId deve essere ${AppConstants.sessionBleIdLength} hex chars',
    );

    try {
      final isSupported = await _peripheral.isSupported;
      if (!isSupported) {
        Log.w('BLE-ADV', 'BLE peripheral non supportato su questo device');
        return false;
      }

      final sessionUuid = AppConstants.buildSessionUuid(sessionBleId);
      await _startUnified(sessionUuid);

      _isAdvertising = true;
      _currentSessionBleId = sessionBleId;
      Log.d(
        'BLE-ADV',
        'Avviato — bleId=$sessionBleId uuid=$sessionUuid',
      );
      return true;
    } catch (e, st) {
      Log.e('BLE-ADV', 'Errore start', e, st);
      _isAdvertising = false;
      _currentSessionBleId = null;
      return false;
    }
  }

  /// Advertise unificato per iOS e Android: solo Service UUID 128-bit
  /// dinamico, niente localName, niente manufacturerData.
  ///
  /// Su Android la libreria flutter_ble_peripheral usa AdvertiseSettings
  /// per il tuning di mode/power. Su iOS questi parametri sono ignorati
  /// (CBPeripheralManager non li espone) — innocui passarli comunque.
  Future<void> _startUnified(String sessionUuid) async {
    final advertiseData = AdvertiseData(
      serviceUuid: sessionUuid,
      includeDeviceName: false,
      // Nessun manufacturerData, nessun localName.
    );

    final advertiseSettings = AdvertiseSettings(
      advertiseMode: AdvertiseMode.advertiseModeLowLatency,
      txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
      connectable: false,
      timeout: 0, // continuo
    );

    await _peripheral.start(
      advertiseData: advertiseData,
      advertiseSettings: advertiseSettings,
    );
  }

  Future<void> stop() async {
    if (!_isAdvertising) return;

    try {
      await _peripheral.stop();
      Log.d('BLE-ADV', 'Fermato');
    } catch (e, st) {
      Log.e('BLE-ADV', 'Errore stop', e, st);
    } finally {
      _isAdvertising = false;
      _currentSessionBleId = null;
    }
  }

  // ── Utilità codec (mantenute: usate dallo scanner per il fallback legacy) ──

  static Uint8List _hexToBytes(String hex) {
    assert(hex.length.isEven, 'hex deve avere lunghezza pari');
    final bytes = List<int>.generate(
      hex.length ~/ 2,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    );
    return Uint8List.fromList(bytes);
  }

  /// Converte un byte array nel sessionBleId hex string.
  /// Usata dallo scanner per decodificare il fallback legacy manufacturerData.
  static String bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
