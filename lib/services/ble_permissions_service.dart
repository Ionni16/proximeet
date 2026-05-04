import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class BlePermissionsService {
  BlePermissionsService._();

  static final BlePermissionsService shared = BlePermissionsService._();

  // Alias per chi usa .instance invece di .shared.
  static BlePermissionsService get instance => shared;

  Future<bool> isBluetoothOn() async {
    if (kIsWeb) return false;

    // Su iOS non blocchiamo il join su questo check.
    // Il permesso Bluetooth lo chiede direttamente il plugin Swift quando serve.
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
    // iOS: non blocchiamo sull'autorizzazione BT, la gestisce CoreBluetooth.
    // Chiediamo solo la Location perché serve per il ranging iBeacon.
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

      // Torniamo sempre true su iOS: anche senza Location si può entrare
      // nell'evento perché BLE GATT funziona comunque.
      return true;
    } catch (e) {
      debugPrint('[BLE-PERM] iOS errore richiesta permessi: $e');
      return true;
    }
  }

  Future<bool> _requestAndroid() async {
    try {
      // Su Android i permessi BLE cambiano tra versione 11 e 12+.
      // Chiediamo tutto, ma non blocchiamo il join se qualcosa manca:
      // su Android 11 i permessi BT runtime non esistono.
      final locationStatus = await Permission.locationWhenInUse.request();
      final scanStatus = await Permission.bluetoothScan.request();
      final advertiseStatus = await Permission.bluetoothAdvertise.request();
      final connectStatus = await Permission.bluetoothConnect.request();

      final locationOk = locationStatus.isGranted;

      // Su Android 12+ scan/advertise/connect devono essere tutti granted.
      // Su Android 11 possono risultare denied ma non è un problema:
      // il plugin nativo fa il check finale e usa solo Fine Location.
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
      // Su iOS saltiamo il check e lasciamo sempre passare.
      return true;
    }

    if (Platform.isAndroid) {
      final location = await Permission.locationWhenInUse.isGranted;
      if (!location) return false;

      final scan = await Permission.bluetoothScan.status;
      final advertise = await Permission.bluetoothAdvertise.status;
      final connect = await Permission.bluetoothConnect.status;

      // Android 12+: se tutti e tre i permessi BT sono ok siamo a posto.
      if (scan.isGranted && advertise.isGranted && connect.isGranted) return true;

      // Android 11 e precedenti: basta la Location.
      // I permessi BT runtime non esistono qui, ci pensa il plugin Kotlin.
      return true;
    }

    return false;
  }
}