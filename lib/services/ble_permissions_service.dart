import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class BlePermissionsService {
  BlePermissionsService._();

  static final BlePermissionsService shared = BlePermissionsService._();

  // Compatibilità con codice che usa .instance
  static BlePermissionsService get instance => shared;

  Future<bool> isBluetoothOn() async {
    if (kIsWeb) return false;

    // Su iOS non blocchiamo mai l'ingresso evento su questo check.
    // CoreBluetooth gestisce il permesso Bluetooth dal plugin nativo.
    if (Platform.isIOS) return true;

    try {
      final state = await FlutterBluePlus.adapterState
          .first
          .timeout(const Duration(seconds: 2));
      return state == BluetoothAdapterState.on;
    } catch (_) {
      return false;
    }
  }

  Future<void> turnOnBluetooth() async {
    if (!Platform.isAndroid) return;

    try {
      await FlutterBluePlus.turnOn();
    } catch (e) {
      debugPrint('[BLE-PERM] Errore turnOn Bluetooth: $e');
    }
  }

  Future<bool> requestAllPermissions() async {
    if (kIsWeb) return false;

    if (Platform.isIOS) {
      return _requestIOS();
    }

    if (Platform.isAndroid) {
      return _requestAndroid();
    }

    return false;
  }

  Future<bool> _requestIOS() async {
    // iOS:
    // - Non bloccare l'ingresso evento sul permesso Bluetooth.
    // - Il prompt Bluetooth viene gestito da CoreBluetooth quando parte il plugin Swift.
    // - Per iBeacon ranging serve Location.
    try {
      var locationStatus = await Permission.locationWhenInUse.status;

      if (locationStatus.isDenied || locationStatus.isRestricted) {
        locationStatus = await Permission.locationWhenInUse.request();
      }

      if (locationStatus.isPermanentlyDenied) {
        debugPrint('[BLE-PERM] iOS location permanentemente negata. Join consentito comunque.');
      } else {
        debugPrint('[BLE-PERM] iOS location status: $locationStatus');
      }

      // Importante: ritorna sempre true su iOS.
      // L'utente deve poter entrare nell'evento anche se iBeacon non parte.
      return true;
    } catch (e) {
      debugPrint('[BLE-PERM] iOS errore richiesta permessi: $e');
      return true;
    }
  }

  Future<bool> _requestAndroid() async {
    try {
      final statuses = await <Permission>[
        Permission.locationWhenInUse,
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ].request();

      final locationOk =
          statuses[Permission.locationWhenInUse]?.isGranted ?? false;
      final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
      final advertiseOk =
          statuses[Permission.bluetoothAdvertise]?.isGranted ?? false;
      final connectOk =
          statuses[Permission.bluetoothConnect]?.isGranted ?? false;

      final ok = locationOk && scanOk && advertiseOk && connectOk;

      debugPrint('[BLE-PERM] Android permissions: $statuses -> $ok');

      return ok;
    } catch (e) {
      debugPrint('[BLE-PERM] Android errore richiesta permessi: $e');
      return false;
    }
  }

  Future<bool> arePermissionsGranted() async {
    if (kIsWeb) return false;

    if (Platform.isIOS) {
      // Non bloccare mai il flusso iOS su questo check.
      return true;
    }

    if (Platform.isAndroid) {
      final location = await Permission.locationWhenInUse.isGranted;
      final scan = await Permission.bluetoothScan.isGranted;
      final advertise = await Permission.bluetoothAdvertise.isGranted;
      final connect = await Permission.bluetoothConnect.isGranted;

      return location && scan && advertise && connect;
    }

    return false;
  }
}