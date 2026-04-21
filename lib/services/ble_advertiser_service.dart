import 'dart:io';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

import '../core/constants.dart';
import '../core/logger.dart';

/// BLE Advertising cross-platform (Android + iOS).
///
/// Strategia robusta:
/// - trasportiamo il sessionBleId SOLO nel localName: "PM-<id>"
/// - NON usiamo serviceUuid / manufacturerData / serviceData
///   perché su Android riempiono il pacchetto e spesso spostano il nome
///   nello scan response, che iOS non sempre espone come ci serve.
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

      final localName = '${AppConstants.bleNamePrefix}$sessionBleId';

      if (Platform.isIOS) {
        await _startIOS(localName);
      } else {
        await _startAndroid(localName);
      }

      _isAdvertising = true;
      _currentSessionBleId = sessionBleId;
      Log.d('BLE-ADV', 'Avviato: $localName');
      return true;
    } catch (e) {
      Log.e('BLE-ADV', 'Errore start', e);
      _isAdvertising = false;
      _currentSessionBleId = null;
      return false;
    }
  }

  Future<void> _startAndroid(String localName) async {
    final advertiseData = AdvertiseData(
      localName: localName,
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
  }

  Future<void> _startIOS(String localName) async {
    final advertiseData = AdvertiseData(
      localName: localName,
      includeDeviceName: false,
    );

    await _peripheral.start(advertiseData: advertiseData);
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
}