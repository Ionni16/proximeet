import 'dart:convert';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import '../models/event_model.dart';
import 'dart:typed_data';

/// Servizio per BLE advertising REALE.
///
/// Trasmette il [sessionBleId] nel manufacturer data in modo che
/// gli scanner degli altri dispositivi possano identificare l'utente.
///
/// Usa [flutter_ble_peripheral] perché [flutter_blue_plus] NON supporta
/// advertising (è solo scanner/central).
class BleAdvertiserService {
  static final BleAdvertiserService shared = BleAdvertiserService._();
  BleAdvertiserService._();

  final _peripheral = FlutterBlePeripheral();
  bool _isAdvertising = false;
  String? _currentSessionBleId;

  bool get isAdvertising => _isAdvertising;
  String? get currentSessionBleId => _currentSessionBleId;

  /// Avvia advertising con il [sessionBleId] come manufacturer data.
  ///
  /// Il service UUID è fisso per l'app ([EventModel.appBleServiceUuid]),
  /// in modo che lo scanner filtri solo per dispositivi ProxiMeet.
  Future<bool> start(String sessionBleId) async {
    if (_isAdvertising) return true;

    try {
      final isSupported = await _peripheral.isSupported;
      if (!isSupported) {
        print('[BLE-ADV] Peripheral advertising non supportato su questo dispositivo');
        return false;
      }

      // Codifica il sessionBleId in bytes (16 hex chars = 8 bytes)
      final sessionBytes = _hexToBytes(sessionBleId);

      final advertiseData = AdvertiseData(
        serviceUuid: EventModel.appBleServiceUuid,
        manufacturerId: 0xFF01, // ID custom ProxiMeet
        manufacturerData: sessionBytes,
      );

      final advertiseSettings = AdvertiseSettings(
        advertiseMode: AdvertiseMode.advertiseModeLowLatency,
        txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
        connectable: false,
        timeout: 0, // nessun timeout — gira finché non lo stoppi
      );

      await _peripheral.start(
        advertiseData: advertiseData,
        advertiseSettings: advertiseSettings,
      );

      _isAdvertising = true;
      _currentSessionBleId = sessionBleId;
      print('[BLE-ADV] Advertising avviato: $sessionBleId');
      return true;
    } catch (e) {
      print('[BLE-ADV] Errore start: $e');
      _isAdvertising = false;
      return false;
    }
  }

  /// Ferma advertising.
  Future<void> stop() async {
    if (!_isAdvertising) return;
    try {
      await _peripheral.stop();
    } catch (e) {
      print('[BLE-ADV] Errore stop: $e');
    }
    _isAdvertising = false;
    _currentSessionBleId = null;
    print('[BLE-ADV] Advertising fermato');
  }

  /// Converte stringa hex in List<int>.
  Uint8List _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final end = (i + 2 <= hex.length) ? i + 2 : hex.length;
      result.add(int.parse(hex.substring(i, end), radix: 16));
    }
    return Uint8List.fromList(result);
  }
}
