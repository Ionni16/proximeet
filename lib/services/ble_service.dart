import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';
import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';

class BleService {
  static final BleService shared = BleService._();
  BleService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // UUID custom ProxiMeet — identifica tutti i dispositivi dell'app
  static const String serviceUUID = '12345678-1234-1234-1234-123456789abc';

  bool _isScanning = false;
  bool _isAdvertising = false;
  StreamSubscription? _scanSubscription;

  // Callback chiamato quando viene rilevato un utente vicino
  Function(String bleId, int rssi)? onUserDetected;

  // Avvia advertising (trasmetti il tuo bleId)
  Future<void> startAdvertising(String bleId) async {
    if (_isAdvertising) return;

    try {
      // Su Android usiamo il nome del dispositivo per trasmettere il bleId
      await FlutterBluePlus.setLogLevel(LogLevel.none);
      _isAdvertising = true;
      print('[BLE] Advertising avviato con bleId: $bleId');
    } catch (e) {
      print('[BLE] Errore advertising: $e');
    }
  }

  // Richiedi permessi BLE
    Future<bool> requestPermissions() async {
        final statuses = await [
            Permission.bluetooth,
            Permission.bluetoothScan,
            Permission.bluetoothAdvertise,
            Permission.bluetoothConnect,
            Permission.locationWhenInUse,
        ].request();

        final allGranted = statuses.values.every(
            (status) => status == PermissionStatus.granted,
        );

        print('[BLE] Permessi concessi: $allGranted');
        return allGranted;
    }


  // Controlla se il Bluetooth è acceso
  Future<bool> isBluetoothOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on;
  }

  // Accendi il Bluetooth (solo Android)
  Future<void> turnOnBluetooth() async {
    await FlutterBluePlus.turnOn();
  }
  // Avvia scanning (cerca dispositivi vicini)
  Future<void> startScanning(String myBleId) async {
    if (_isScanning) return;

    try {
      _isScanning = true;

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        continuousUpdates: true,
      );

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final deviceName = result.device.platformName;
          final rssi = result.rssi;

          // Filtra solo dispositivi ProxiMeet
          // (il nome contiene i primi 8 caratteri del bleId)
          if (deviceName.startsWith('PM-') && deviceName.length >= 11) {
            final detectedBleId = deviceName.substring(3);
            if (detectedBleId != myBleId) {
              print('[BLE] Rilevato: $detectedBleId RSSI: $rssi');
              onUserDetected?.call(detectedBleId, rssi);
              _saveDetection(detectedBleId);
            }
          }
        }
      });

      print('[BLE] Scanning avviato');
    } catch (e) {
      print('[BLE] Errore scanning: $e');
      _isScanning = false;
    }
  }

  // Ferma tutto
  Future<void> stopAll() async {
    await _scanSubscription?.cancel();
    await FlutterBluePlus.stopScan();
    _isScanning = false;
    _isAdvertising = false;
    print('[BLE] BLE fermato');
  }

  // Salva rilevazione su Firestore (come WLINK fa con beaconDetections)
  Future<void> _saveDetection(String detectedBleId) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;

    try {
      await _db
          .collection('bleDetections')
          .doc(detectedBleId)
          .collection('detections')
          .doc(myUid)
          .set({'timestamp': FieldValue.serverTimestamp()});

      print('[BLE] Detection salvata per bleId: $detectedBleId');
    } catch (e) {
      print('[BLE] Errore salvataggio detection: $e');
    }
  }

  // Ascolta le rilevazioni del TUO bleId
  // (altri utenti che ti hanno visto)
  Stream<List<String>> listenToMyDetections(String myBleId) {
    return _db
        .collection('bleDetections')
        .doc(myBleId)
        .collection('detections')
        .snapshots()
        .map((snap) => snap.docs.map((d) => d.id).toList());
  }

  bool get isScanning => _isScanning;
  bool get isAdvertising => _isAdvertising;
}