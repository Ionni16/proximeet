import '../models/nearby_user.dart';
import 'platform_beacon_service.dart';

class BleScannerService {
  BleScannerService._();

  static final BleScannerService shared = BleScannerService._();

  // Alias per chi usa .instance invece di .shared.
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

    // Lo scan vero lo fa PlatformBeaconService col plugin nativo.
    // Questo wrapper esiste solo per non cambiare l'interfaccia di NearbyDetectionService.
  }

  Future<void> stop() async {
    _isScanning = false;
    _mySessionBleId = null;

    // Non fermiamo PlatformBeaconService qui: lo fa già BleAdvertiserService.stop().
    // Chiamarlo due volte causerebbe una race condition.
  }

  void dispose() {
    _isScanning = false;
    _mySessionBleId = null;
  }
}