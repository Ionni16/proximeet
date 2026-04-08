import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// Gestione centralizzata dei permessi BLE e location.
///
/// Differenze chiave Android/iOS:
/// - Android 12+: serve bluetoothScan, bluetoothAdvertise, bluetoothConnect
/// - Android <12: serve solo location
/// - iOS: i permessi BLE vengono chiesti automaticamente dal sistema al primo
///   uso; serve solo il Bluetooth permission + la dichiarazione in Info.plist
class BlePermissionsService {
  static final BlePermissionsService shared = BlePermissionsService._();
  BlePermissionsService._();

  Future<bool> isBluetoothOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on;
  }

  /// Tenta di accendere il Bluetooth (solo Android, iOS non lo permette).
  Future<void> turnOnBluetooth() async {
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        print('[BLE-PERM] Errore turnOn: $e');
      }
    }
    // Su iOS non si può accendere il BT programmaticamente.
    // L'utente vedrà il dialog di sistema automaticamente.
  }

  /// Richiedi tutti i permessi necessari.
  Future<bool> requestAllPermissions() async {
    if (Platform.isIOS) {
      return await _requestIOS();
    } else {
      return await _requestAndroid();
    }
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

    print('[BLE-PERM] Android permessi: $statuses → $allGranted');
    return allGranted;
  }

  Future<bool> _requestIOS() async {
    // Su iOS, il permesso Bluetooth viene chiesto automaticamente dal sistema
    // quando l'app tenta di usare CoreBluetooth. Ma possiamo forzarlo:
    final btStatus = await Permission.bluetooth.request();

    // Location non è strettamente necessario per BLE su iOS,
    // ma lo chiediamo per compatibilità con alcuni device/versioni
    final locStatus = await Permission.locationWhenInUse.request();

    final granted = (btStatus == PermissionStatus.granted ||
            btStatus == PermissionStatus.limited) &&
        (locStatus == PermissionStatus.granted ||
            locStatus == PermissionStatus.limited);

    print('[BLE-PERM] iOS permessi: bt=$btStatus loc=$locStatus → $granted');
    return granted;
  }

  Future<bool> arePermissionsGranted() async {
    if (Platform.isIOS) {
      final bt = await Permission.bluetooth.isGranted;
      return bt;
    }
    final scan = await Permission.bluetoothScan.isGranted;
    final adv = await Permission.bluetoothAdvertise.isGranted;
    final conn = await Permission.bluetoothConnect.isGranted;
    final loc = await Permission.locationWhenInUse.isGranted;
    return scan && adv && conn && loc;
  }
}
