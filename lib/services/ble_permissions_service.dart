import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// Gestione centralizzata dei permessi BLE e location.
///
/// Racchiude tutte le differenze Android/iOS in un unico punto.
class BlePermissionsService {
  static final BlePermissionsService shared = BlePermissionsService._();
  BlePermissionsService._();

  /// Controlla se il Bluetooth è acceso.
  Future<bool> isBluetoothOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on;
  }

  /// Tenta di accendere il Bluetooth (solo Android).
  Future<void> turnOnBluetooth() async {
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        print('[BLE-PERM] Errore turnOn: $e');
      }
    }
  }

  /// Richiedi tutti i permessi necessari per BLE advertising + scanning.
  /// Restituisce true se tutti i permessi sono concessi.
  Future<bool> requestAllPermissions() async {
    final permissions = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];

    // Su Android < 12, bluetooth scan/advertise/connect non esistono
    // ma permission_handler gestisce il fallback.
    final statuses = await permissions.request();

    final allGranted = statuses.values.every(
      (status) =>
          status == PermissionStatus.granted ||
          status == PermissionStatus.limited,
    );

    print('[BLE-PERM] Permessi: $statuses → allGranted=$allGranted');
    return allGranted;
  }

  /// Controlla se tutti i permessi sono già concessi (senza chiedere).
  Future<bool> arePermissionsGranted() async {
    final scan = await Permission.bluetoothScan.isGranted;
    final adv = await Permission.bluetoothAdvertise.isGranted;
    final conn = await Permission.bluetoothConnect.isGranted;
    final loc = await Permission.locationWhenInUse.isGranted;
    return scan && adv && conn && loc;
  }
}
