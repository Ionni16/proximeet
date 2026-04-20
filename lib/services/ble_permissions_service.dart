import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/logger.dart';

/// Gestione centralizzata dei permessi BLE e location.
///
/// Singleton: usa [BlePermissionsService.instance].
class BlePermissionsService {
  BlePermissionsService._();
  static final BlePermissionsService instance = BlePermissionsService._();

  Future<bool> isBluetoothOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on;
  }

  Future<void> turnOnBluetooth() async {
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        Log.e('BLE-PERM', 'Errore turnOn', e);
      }
    }
  }

  Future<bool> requestAllPermissions() async {
    if (Platform.isIOS) return await _requestIOS();
    return await _requestAndroid();
  }

  Future<bool> _requestAndroid() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final allGranted = statuses.values.every(
      (s) => s == PermissionStatus.granted || s == PermissionStatus.limited,
    );

    Log.d('BLE-PERM', 'Android permessi: $allGranted');
    return allGranted;
  }

  Future<bool> _requestIOS() async {
    // iOS 13+: BLE non richiede location permission.
    // CoreBluetooth gestisce il permesso automaticamente al primo uso.
    // Basta verificare che il Bluetooth sia acceso.
    final bleState = await FlutterBluePlus.adapterState.first;
    final bleOk = bleState == BluetoothAdapterState.on;

    Log.d('BLE-PERM', 'iOS: bleState=$bleState → $bleOk');
    return bleOk;
  }

  Future<bool> arePermissionsGranted() async {
    if (Platform.isIOS) {
      final bleState = await FlutterBluePlus.adapterState.first;
      return bleState == BluetoothAdapterState.on;
    }
    final scan = await Permission.bluetoothScan.isGranted;
    final adv = await Permission.bluetoothAdvertise.isGranted;
    final conn = await Permission.bluetoothConnect.isGranted;
    final loc = await Permission.locationWhenInUse.isGranted;
    return scan && adv && conn && loc;
  }
}
