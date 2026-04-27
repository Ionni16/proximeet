import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/logger.dart';

/// Gestione centralizzata permessi Bluetooth/Location.
///
/// Per iBeacon su iOS serve Location When In Use/Always oltre al Bluetooth,
/// perché il ranging passa da CoreLocation. Non blocchiamo l'utente se il
/// bluetooth state non è immediatamente leggibile: il plugin nativo gestirà
/// l'errore e il join evento continuerà comunque.
class BlePermissionsService {
  BlePermissionsService._();
  static final BlePermissionsService instance = BlePermissionsService._();

  Future<bool> isBluetoothOn() async {
    try {
      final state = await FlutterBluePlus.adapterState
          .first
          .timeout(const Duration(seconds: 3));
      return state == BluetoothAdapterState.on;
    } catch (e, st) {
      Log.e('BLE-PERM', 'Impossibile leggere stato Bluetooth', e, st);
      // Non bloccare l'app: su iOS lo stato può arrivare tardi.
      return Platform.isIOS;
    }
  }

  Future<void> turnOnBluetooth() async {
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e, st) {
        Log.e('BLE-PERM', 'Errore turnOn', e, st);
      }
    }
  }

  Future<bool> requestAllPermissions() async {
    if (Platform.isIOS) return _requestIOS();
    return _requestAndroid();
  }

  Future<bool> _requestAndroid() async {
    final statuses = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final allGranted = statuses.values.every(_isGrantedEnough);
    Log.d('BLE-PERM', 'Android permessi: $statuses → $allGranted');
    return allGranted;
  }

  Future<bool> _requestIOS() async {
    final statuses = await <Permission>[
      Permission.bluetooth,
      Permission.locationWhenInUse,
    ].request();

    final bluetoothOk = _isGrantedEnough(
      statuses[Permission.bluetooth] ?? await Permission.bluetooth.status,
    );
    final locationOk = _isGrantedEnough(
      statuses[Permission.locationWhenInUse] ??
          await Permission.locationWhenInUse.status,
    );

    Log.d(
      'BLE-PERM',
      'iOS permessi: bluetooth=$bluetoothOk location=$locationOk raw=$statuses',
    );

    return bluetoothOk && locationOk;
  }

  Future<bool> arePermissionsGranted() async {
    if (Platform.isIOS) {
      final bluetoothOk = _isGrantedEnough(await Permission.bluetooth.status);
      final locationOk =
          _isGrantedEnough(await Permission.locationWhenInUse.status) ||
              _isGrantedEnough(await Permission.locationAlways.status);
      return bluetoothOk && locationOk;
    }

    final scan = await Permission.bluetoothScan.isGranted;
    final adv = await Permission.bluetoothAdvertise.isGranted;
    final conn = await Permission.bluetoothConnect.isGranted;
    final loc = await Permission.locationWhenInUse.isGranted;
    return scan && adv && conn && loc;
  }

  bool _isGrantedEnough(PermissionStatus status) {
    return status == PermissionStatus.granted ||
        status == PermissionStatus.limited ||
        status == PermissionStatus.provisional;
  }
}
