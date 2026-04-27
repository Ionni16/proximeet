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
      // BLE scan/advertise cambia tra Android <= 11 e Android 12+.
      // Chiediamo tutti i permessi utili, ma NON blocchiamo il join solo perché
      // un permesso Android 12+ risulta “denied” su device Android 11 o inferiori.
      final locationStatus = await Permission.locationWhenInUse.request();
      final scanStatus = await Permission.bluetoothScan.request();
      final advertiseStatus = await Permission.bluetoothAdvertise.request();
      final connectStatus = await Permission.bluetoothConnect.request();

      final locationOk = locationStatus.isGranted;

      // Su Android 12+ questi devono essere granted. Su Android <= 11 alcuni
      // device/plugin li riportano denied/not applicable: in quel caso il check
      // reale viene fatto dal plugin nativo, che richiede solo Fine Location.
      final android12PermsOk =
          scanStatus.isGranted && advertiseStatus.isGranted && connectStatus.isGranted;

      final ok = locationOk && (android12PermsOk ||
          scanStatus.isDenied || advertiseStatus.isDenied || connectStatus.isDenied);

      debugPrint(
        '[BLE-PERM] Android permissions: '
        'location=$locationStatus scan=$scanStatus '
        'advertise=$advertiseStatus connect=$connectStatus -> $ok',
      );

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
      if (!location) return false;

      final scan = await Permission.bluetoothScan.status;
      final advertise = await Permission.bluetoothAdvertise.status;
      final connect = await Permission.bluetoothConnect.status;

      // Android 12+: tutti e tre granted.
      if (scan.isGranted && advertise.isGranted && connect.isGranted) return true;

      // Android <= 11: Fine Location è sufficiente; i permessi Bluetooth runtime
      // possono risultare denied/non applicabili. Il plugin Kotlin farà il check
      // definitivo prima di avviare scan/advertising.
      return true;
    }

    return false;
  }
}