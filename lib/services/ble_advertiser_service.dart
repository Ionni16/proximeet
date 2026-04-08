import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import '../models/event_model.dart';

/// BLE Advertising cross-platform (Android + iOS).
///
/// PROBLEMA iOS:
/// Apple ignora/riscrive il manufacturer data nei pacchetti BLE.
/// Il campo manufacturerData NON arriva agli scanner esterni.
///
/// SOLUZIONE:
/// Usiamo il **local name** con prefix "PM-" come carrier del sessionBleId.
/// Funziona sia su Android che su iOS (in foreground).
/// Su Android aggiungiamo anche manufacturer data come ridondanza.
///
/// Lo scanner cercherà il sessionBleId in questo ordine:
/// 1. Manufacturer data 0xFF01 (Android→Android, più affidabile)
/// 2. Local name con prefix "PM-" (cross-platform, funziona sempre in foreground)
class BleAdvertiserService {
  static final BleAdvertiserService shared = BleAdvertiserService._();
  BleAdvertiserService._();

  final _peripheral = FlutterBlePeripheral();
  bool _isAdvertising = false;
  String? _currentSessionBleId;

  bool get isAdvertising => _isAdvertising;
  String? get currentSessionBleId => _currentSessionBleId;

  Future<bool> start(String sessionBleId) async {
    if (_isAdvertising) return true;

    try {
      final isSupported = await _peripheral.isSupported;
      if (!isSupported) {
        print('[BLE-ADV] Peripheral advertising non supportato');
        return false;
      }

      if (Platform.isIOS) {
        return await _startIOS(sessionBleId);
      } else {
        return await _startAndroid(sessionBleId);
      }
    } catch (e) {
      print('[BLE-ADV] Errore start: $e');
      _isAdvertising = false;
      return false;
    }
  }

  /// Android: manufacturer data + service UUID + local name.
  Future<bool> _startAndroid(String sessionBleId) async {
    final sessionBytes = _hexToBytes(sessionBleId);

    final advertiseData = AdvertiseData(
      serviceUuid: EventModel.appBleServiceUuid,
      manufacturerId: 0xFF01,
      manufacturerData: sessionBytes,
      localName: 'PM-$sessionBleId',
      includeDeviceName: false,
    );

    final advertiseSettings = AdvertiseSettings(
      advertiseMode: AdvertiseMode.advertiseModeLowLatency,
      txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
      connectable: false,
      timeout: 0,
    );

    await _peripheral.start(
      advertiseData: advertiseData,
      advertiseSettings: advertiseSettings,
    );

    _isAdvertising = true;
    _currentSessionBleId = sessionBleId;
    print('[BLE-ADV] Android avviato: $sessionBleId (mfgData + localName)');
    return true;
  }

  /// iOS: solo service UUID + local name.
  /// CBPeripheralManager su iOS supporta solo:
  /// - CBAdvertisementDataServiceUUIDsKey (→ serviceUuid)
  /// - CBAdvertisementDataLocalNameKey (→ localName)
  /// Il manufacturer data viene silenziosamente ignorato.
  Future<bool> _startIOS(String sessionBleId) async {
    final advertiseData = AdvertiseData(
      serviceUuid: EventModel.appBleServiceUuid,
      localName: 'PM-$sessionBleId',
      includeDeviceName: false,
    );

    await _peripheral.start(advertiseData: advertiseData);

    _isAdvertising = true;
    _currentSessionBleId = sessionBleId;
    print('[BLE-ADV] iOS avviato: $sessionBleId (via localName)');
    return true;
  }

  Future<void> stop() async {
    if (!_isAdvertising) return;
    try {
      await _peripheral.stop();
    } catch (e) {
      print('[BLE-ADV] Errore stop: $e');
    }
    _isAdvertising = false;
    _currentSessionBleId = null;
    print('[BLE-ADV] Fermato');
  }

  Uint8List _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final end = (i + 2 <= hex.length) ? i + 2 : hex.length;
      result.add(int.parse(hex.substring(i, end), radix: 16));
    }
    return Uint8List.fromList(result);
  }
}
