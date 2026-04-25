import '../core/logger.dart';
import 'platform_beacon_service.dart';

class BleAdvertiserService {
  BleAdvertiserService._();
  static final BleAdvertiserService instance = BleAdvertiserService._();

  bool get isAdvertising => PlatformBeaconService.instance.isRunning;
  String? get currentSessionBleId => PlatformBeaconService.instance.myBeaconKey;

  Future<bool> start(String sessionBleId) async {
    final ok = await PlatformBeaconService.instance.start(sessionBleId);
    Log.d('BLE-ADV', ok ? 'Beacon advertising avviato' : 'Beacon advertising fallito');
    return ok;
  }

  Future<void> stop() async => PlatformBeaconService.instance.stop();

  static String bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
