abstract final class AppConstants {
  static const String proximeetBeaconUuid =
      'F2703C30-FA18-4173-8599-016070383C81';

  /// Compatibilità col codice esistente: ora sessionBleId = beaconKey "major_minor".
  static const int sessionBleIdLength = 11;

  static String beaconKey(int major, int minor) {
    return '${major.toString().padLeft(5, '0')}_${minor.toString().padLeft(5, '0')}';
  }

  static ({int major, int minor}) parseBeaconKey(String key) {
    final parts = key.split('_');
    if (parts.length != 2) throw FormatException('beaconKey non valido: $key');
    final major = int.parse(parts[0]);
    final minor = int.parse(parts[1]);
    if (major < 0 || major > 65535 || minor < 0 || minor > 65535) {
      throw FormatException('major/minor fuori range: $key');
    }
    return (major: major, minor: minor);
  }

  static bool isValidBeaconKey(String key) {
    try {
      parseBeaconKey(key);
      return true;
    } catch (_) {
      return false;
    }
  }

  static const int scanIntervalSeconds = 8;
  static const int scanDurationSeconds = 5;
  static const int staleThresholdSeconds = 60;
  static const int cleanupIntervalSeconds = 15;
  static const int contactGatingSeconds = 120;
  static const int heartbeatIntervalSeconds = 30;
  static const int rssiVeryClose = -50;
  static const int rssiClose = -65;
  static const int rssiMedium = -80;
  static const int primarySeedColor = 0xFF1D9E75;
  static const int detectionWriteDebounceSeconds = 20;
  static const int nearbyResolveTtlSeconds = 120;
}
