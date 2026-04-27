import 'platform_beacon_service.dart';

class BleAdvertiserService {
  BleAdvertiserService._();

  static final BleAdvertiserService shared = BleAdvertiserService._();

  // Compatibilità con codice che usa .instance
  static BleAdvertiserService get instance => shared;

  bool get isAdvertising => PlatformBeaconService.instance.isRunning;

  String? get currentSessionBleId => PlatformBeaconService.instance.myBeaconKey;

  Future<bool> start(String sessionBleId) async {
    return PlatformBeaconService.instance.start(sessionBleId);
  }

  Future<void> stop() async {
    await PlatformBeaconService.instance.stop();
  }

  void dispose() {
    PlatformBeaconService.instance.dispose();
  }
}