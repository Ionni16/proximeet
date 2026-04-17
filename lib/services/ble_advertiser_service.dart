import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

import '../core/constants.dart';
import '../core/logger.dart';

/// BLE Advertising cross-platform (Android + iOS).
///
/// SOLUZIONE iOS:
/// Apple ignora manufacturer data nei pacchetti BLE.
/// Usiamo il local name con prefix "PM-" come carrier del sessionBleId.
/// Su Android aggiungiamo anche manufacturer data come ridondanza.
///
/// Singleton: usa [BleAdvertiserService.instance].
class BleAdvertiserService {
  BleAdvertiserService._();
  static final BleAdvertiserService instance = BleAdvertiserService._();

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
        Log.w('BLE-ADV', 'Peripheral advertising non supportato');
        return false;
      }

      if (Platform.isIOS) {
        return await _startIOS(sessionBleId);
      } else {
        return await _startAndroid(sessionBleId);
      }
    } catch (e) {
      Log.e('BLE-ADV', 'Errore start', e);
      _isAdvertising = false;
      return false;
    }
  }

  Future<bool> _startAndroid(String sessionBleId) async {
    final sessionBytes = _hexToBytes(sessionBleId);

    final advertiseData = AdvertiseData(
      serviceUuid: AppConstants.bleServiceUuid,
      manufacturerId: AppConstants.bleManufacturerId,
      manufacturerData: sessionBytes,
      localName: '${AppConstants.bleNamePrefix}$sessionBleId',
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
    Log.d('BLE-ADV', 'Android avviato: $sessionBleId');
    return true;
  }

  Future<bool> _startIOS(String sessionBleId) async {
    final advertiseData = AdvertiseData(
      serviceUuid: AppConstants.bleServiceUuid,
      localName: '${AppConstants.bleNamePrefix}$sessionBleId',
      includeDeviceName: false,
    );

    await _peripheral.start(advertiseData: advertiseData);

    _isAdvertising = true;
    _currentSessionBleId = sessionBleId;
    Log.d('BLE-ADV', 'iOS avviato: $sessionBleId');
    return true;
  }

  Future<void> stop() async {
    if (!_isAdvertising) return;
    try {
      await _peripheral.stop();
    } catch (e) {
      Log.e('BLE-ADV', 'Errore stop', e);
    }
    _isAdvertising = false;
    _currentSessionBleId = null;
    Log.d('BLE-ADV', 'Fermato');
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
