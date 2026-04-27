import '../models/nearby_user.dart';
import 'platform_beacon_service.dart';

class BleScannerService {
  BleScannerService._();

  static final BleScannerService shared = BleScannerService._();

  // Compatibilità con codice che usa .instance
  static BleScannerService get instance => shared;

  bool _isScanning = false;
  String? _mySessionBleId;

  Stream<RawBleDetection> get detections =>
      PlatformBeaconService.instance.detections;

  bool get isScanning => _isScanning;

  String? get mySessionBleId => _mySessionBleId;

  Future<void> start({
    required String mySessionBleId,
    int intervalSeconds = 8,
    int scanDurationSeconds = 5,
  }) async {
    _isScanning = true;
    _mySessionBleId = mySessionBleId;

    // Lo scan reale è già gestito dal plugin nativo tramite PlatformBeaconService.
    // Questo wrapper serve per mantenere compatibile NearbyDetectionService.
  }

  Future<void> stop() async {
    _isScanning = false;
    _mySessionBleId = null;

    // Non chiamiamo PlatformBeaconService.stop() qui.
    // Lo stop reale viene fatto da BleAdvertiserService.stop(),
    // così evitiamo doppio stop e race condition.
  }

  void dispose() {
    _isScanning = false;
    _mySessionBleId = null;
  }
}