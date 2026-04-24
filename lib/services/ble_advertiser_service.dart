import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

import '../core/constants.dart';
import '../core/logger.dart';

/// BLE Advertising — singleton cross-platform.
///
/// ─── Protocollo ──────────────────────────────────────────────────────────────
///
/// L'obiettivo è trasportare il sessionBleId (16 hex chars = 8 byte) nel
/// main advertising packet, NON nel scan response. Il scan response è un
/// pacchetto separato che il central richiede esplicitamente via SCAN_REQUEST:
/// iOS Core Bluetooth lo richiede raramente (usa la cache), quindi qualsiasi
/// dato trasmesso solo nel scan response può essere invisibile a iOS.
///
/// ── Android (peripheral) ──────────────────────────────────────────────────
///   Carrier: Manufacturer Specific Data
///   Motivo: il campo manufacturerData va SEMPRE nel main advertising packet.
///   Non includiamo localName per tenere il payload al minimo e non rischiare
///   che il BLE stack Android lo sposti nello scan response.
///
///   Struttura pacchetto (17 byte su 31 disponibili):
///     FLAGS              3B
///     Service UUID 16bit 4B   (0xFAAB)
///     Manufacturer Data 10B   (type 1B + len 1B + companyId 2B + bleId 8B)
///
/// ── iOS (peripheral) ──────────────────────────────────────────────────────
///   Carrier: Local Name  →  "PM-{sessionBleId}"
///   Motivo: CBPeripheralManager non espone API per manufacturer data custom.
///   In foreground iOS include localName nel main packet.
///   In background iOS strip il localName e trasmette solo serviceUuid
///   (limite OS non aggirabile — accettato nel design).
///
///   Struttura pacchetto foreground (28 byte su 31 disponibili):
///     FLAGS              3B
///     Service UUID 16bit 4B   (0xFAAB)
///     Local Name        21B   (type 1B + len 1B + "PM-" 3B + hex 16B)
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

      if (Platform.isAndroid) {
        await _startAndroid(sessionBleId);
      } else {
        await _startIOS(sessionBleId);
      }

      _isAdvertising = true;
      _currentSessionBleId = sessionBleId;
      Log.d(
        'BLE-ADV',
        'Avviato — platform=${Platform.operatingSystem} '
        'bleId=$sessionBleId '
        'carrier=${Platform.isAndroid ? "manufacturerData" : "localName"}',
      );
      return true;
    } catch (e, st) {
      Log.e('BLE-ADV', 'Errore start', e, st);
      _isAdvertising = false;
      _currentSessionBleId = null;
      return false;
    }
  }

  /// Android: manufacturer data come carrier primario e unico dell'ID.
  ///
  /// Non includiamo localName deliberatamente:
  ///   - risparmia byte nel payload
  ///   - elimina il rischio che il BLE stack lo sposti nel scan response
  ///   - la detection iOS avviene esclusivamente via manufacturerData
  Future<void> _startAndroid(String sessionBleId) async {
    final advertiseData = AdvertiseData(
      serviceUuid: AppConstants.bleServiceUuid,
      manufacturerId: AppConstants.bleManufacturerId,
      manufacturerData: _hexToBytes(sessionBleId),
      includeDeviceName: false,
    );

    final advertiseSettings = AdvertiseSettings(
      advertiseMode: AdvertiseMode.advertiseModeLowLatency,
      txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
      connectable: false,
      timeout: 0, // advertising continuo
    );

    await _peripheral.start(
      advertiseData: advertiseData,
      advertiseSettings: advertiseSettings,
    );
  }

  /// iOS: localName come carrier primario dell'ID.
  ///
  /// Limite noto: in background iOS trasmette solo serviceUuid.
  /// In foreground trasmette serviceUuid + localName nel main packet.
  /// Non esiste API pubblica per aggirare questo limite su iOS.
  Future<void> _startIOS(String sessionBleId) async {
    final localName = '${AppConstants.bleNamePrefix}$sessionBleId';

    final advertiseData = AdvertiseData(
      serviceUuid: AppConstants.bleServiceUuid,
      localName: localName,
      includeDeviceName: false,
    );

    await _peripheral.start(advertiseData: advertiseData);
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

  // ── Utilità codec ─────────────────────────────────────────────────────────

  /// Converte una stringa hex (es. "a1b2c3d4e5f60708") in byte array.
  /// Usata per codificare il sessionBleId nel campo manufacturer data.
  static Uint8List _hexToBytes(String hex) {
    assert(hex.length.isEven, 'hex deve avere lunghezza pari');
    final bytes = List<int>.generate(
      hex.length ~/ 2,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    );
    return Uint8List.fromList(bytes);
  }

  /// Converte un byte array nel sessionBleId hex string.
  /// Usata dallo scanner per decodificare il campo manufacturer data.
  static String bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
