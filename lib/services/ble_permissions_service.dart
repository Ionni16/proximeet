import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class BlePermissionsService {
  BlePermissionsService._();

  static final BlePermissionsService shared = BlePermissionsService._();

  // Alias per chi usa .instance invece di .shared.
  static BlePermissionsService get instance => shared;

  // Cache della versione Android per non interrogare il device ogni volta.
  int? _androidSdkInt;

  /// Ritorna l'API level di Android (es. 31 = Android 12).
  /// Su piattaforme non-Android ritorna 0.
  Future<int> _getAndroidSdkInt() async {
    if (!Platform.isAndroid) return 0;
    if (_androidSdkInt != null) return _androidSdkInt!;
    final info = await DeviceInfoPlugin().androidInfo;
    _androidSdkInt = info.version.sdkInt;
    return _androidSdkInt!;
  }

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
      final sdkInt = await _getAndroidSdkInt();

      // Android 12+ (API 31): il BLE usa i permessi BLUETOOTH_SCAN/ADVERTISE/CONNECT.
      // La location NON serve e non viene mai concessa (flag neverForLocation nel
      // manifest), quindi NON va richiesta e NON va inclusa nel check.
      if (sdkInt >= 31) {
        final statuses = await [
          Permission.bluetoothScan,
          Permission.bluetoothAdvertise,
          Permission.bluetoothConnect,
        ].request();

        final ok = statuses.values.every((s) => s.isGranted);

        debugPrint(
          '[BLE-PERM] Android 12+ permissions: '
          'scan=${statuses[Permission.bluetoothScan]} '
          'advertise=${statuses[Permission.bluetoothAdvertise]} '
          'connect=${statuses[Permission.bluetoothConnect]} -> $ok',
        );

        return ok;
      }

      // Android 11 e precedenti (API <= 30): il BLE scan/advertise richiede
      // solo ACCESS_FINE_LOCATION. I permessi BLUETOOTH_* runtime non esistono.
      final locationStatus = await Permission.locationWhenInUse.request();
      final ok = locationStatus.isGranted;

      debugPrint('[BLE-PERM] Android <=11 permissions: location=$locationStatus -> $ok');

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
      final sdkInt = await _getAndroidSdkInt();

      // Android 12+: contano SOLO i tre permessi bluetooth. Niente location.
      if (sdkInt >= 31) {
        final scan = await Permission.bluetoothScan.isGranted;
        final advertise = await Permission.bluetoothAdvertise.isGranted;
        final connect = await Permission.bluetoothConnect.isGranted;
        return scan && advertise && connect;
      }

      // Android 11 e precedenti: basta la Location.
      return await Permission.locationWhenInUse.isGranted;
    }

    return false;
  }
}
