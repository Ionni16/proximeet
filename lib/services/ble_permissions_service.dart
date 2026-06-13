import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// Gestione dei permessi BLE, con la consapevolezza che su Android i
/// permessi cambiano radicalmente tra le versioni:
///
///   • Android ≤ 11 (API ≤ 30): il BLE scan richiede ACCESS_FINE_LOCATION;
///     i permessi runtime BLUETOOTH_SCAN/ADVERTISE/CONNECT NON esistono.
///   • Android 12+ (API ≥ 31): servono BLUETOOTH_SCAN/ADVERTISE/CONNECT;
///     la posizione NON serve (usiamo neverForLocation nel manifest).
///   • Android 13+ (API ≥ 33): per le notifiche serve POST_NOTIFICATIONS.
///
/// Il vecchio codice trattava "permesso non richiedibile su Android ≤11"
/// e "permesso negato su 12+" allo stesso modo, restituendo true anche
/// quando un permesso necessario era stato negato. Qui distinguiamo i
/// casi in base a sdkInt, così lo stato riportato è veritiero.
class BlePermissionsService {
  BlePermissionsService._();

  static final BlePermissionsService shared = BlePermissionsService._();

  // Alias per chi usa .instance invece di .shared.
  static BlePermissionsService get instance => shared;

  static const _tag = 'BLE-PERM';

  // Cache della versione Android per non interrogare il device ogni volta.
  int? _androidSdkInt;

  /// API level di Android (es. 31 = Android 12). 0 se non Android.
  Future<int> _sdkInt() async {
    if (!Platform.isAndroid) return 0;
    if (_androidSdkInt != null) return _androidSdkInt!;
    final info = await DeviceInfoPlugin().androidInfo;
    _androidSdkInt = info.version.sdkInt;
    return _androidSdkInt!;
  }

  Future<bool> isBluetoothOn() async {
    if (kIsWeb) return false;

    // Su iOS non blocchiamo il join su questo check:
    // il permesso Bluetooth lo chiede CoreBluetooth quando serve.
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
      debugPrint('[$_tag] Errore turnOn Bluetooth: $e');
    }
  }

  /// Richiede tutti i permessi necessari per la piattaforma/versione.
  /// Ritorna true se i permessi NECESSARI sono concessi.
  Future<bool> requestAllPermissions() async {
    if (kIsWeb) return false;
    if (Platform.isIOS) return _requestIOS();
    if (Platform.isAndroid) return _requestAndroid();
    return false;
  }

  Future<bool> _requestIOS() async {
    // iOS: non blocchiamo sull'autorizzazione BT (la gestisce CoreBluetooth).
    // Chiediamo la Location perché serve al ranging iBeacon, ma anche senza
    // si può entrare nell'evento perché il BLE GATT funziona comunque.
    try {
      var status = await Permission.locationWhenInUse.status;
      if (status.isDenied || status.isRestricted) {
        status = await Permission.locationWhenInUse.request();
      }
      debugPrint('[$_tag] iOS location status: $status');
      await _requestNotifications();
      return true;
    } catch (e) {
      debugPrint('[$_tag] iOS errore richiesta permessi: $e');
      return true;
    }
  }

  Future<bool> _requestAndroid() async {
    try {
      await _requestNotifications();

      final sdkInt = await _sdkInt();

      if (sdkInt >= 31) {
        // Android 12+: contano SOLO scan/advertise/connect. La posizione
        // non serve (neverForLocation), quindi non la richiediamo.
        final results = await [
          Permission.bluetoothScan,
          Permission.bluetoothAdvertise,
          Permission.bluetoothConnect,
        ].request();

        final granted = results.values.every((s) => s.isGranted);
        debugPrint('[$_tag] Android $sdkInt BT perms: $results -> $granted');
        return granted;
      }

      // Android ≤ 11: il BLE scan dipende da ACCESS_FINE_LOCATION.
      // I permessi BT runtime non esistono qui.
      final status = await Permission.locationWhenInUse.request();
      final granted = status.isGranted;
      debugPrint('[$_tag] Android $sdkInt location: $status -> $granted');
      return granted;
    } catch (e) {
      debugPrint('[$_tag] Android errore richiesta permessi: $e');
      return false;
    }
  }

  /// POST_NOTIFICATIONS (Android 13+) / autorizzazione notifiche iOS.
  /// Best-effort: il suo esito non incide sul join all'evento.
  Future<void> _requestNotifications() async {
    try {
      if (Platform.isAndroid) {
        final sdkInt = await _sdkInt();
        if (sdkInt < 33) return; // prima di Android 13 non esiste il permesso
      }
      final status = await Permission.notification.status;
      if (status.isDenied) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint('[$_tag] Errore richiesta permesso notifiche: $e');
    }
  }

  /// Verifica (senza richiedere) se i permessi NECESSARI sono concessi.
  Future<bool> arePermissionsGranted() async {
    if (kIsWeb) return false;

    // iOS: lasciamo sempre passare, la gestione è di CoreBluetooth.
    if (Platform.isIOS) return true;

    if (Platform.isAndroid) {
      final sdkInt = await _sdkInt();

      if (sdkInt >= 31) {
        // Android 12+: tutti e tre i permessi BT devono essere concessi.
        final scan = await Permission.bluetoothScan.isGranted;
        final advertise = await Permission.bluetoothAdvertise.isGranted;
        final connect = await Permission.bluetoothConnect.isGranted;
        return scan && advertise && connect;
      }

      // Android ≤ 11: basta la Location.
      return Permission.locationWhenInUse.isGranted;
    }

    return false;
  }
}
