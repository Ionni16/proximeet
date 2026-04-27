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

  // ── Soglie RSSI (dBm) calibrate per BLE iBeacon con EWMA smoothing ──────
  //
  // Valori RSSI tipici per BLE iBeacon (TX power -59 dBm, ambienti reali):
  //   0-0.5 m  → RSSI ≈ -40 / -60 dBm
  //   1-2 m    → RSSI ≈ -60 / -72 dBm
  //   3-5 m    → RSSI ≈ -72 / -82 dBm
  //   > 5 m    → RSSI < -82 dBm
  //
  // Con EWMA smoothing (α=0.25 nativo + α=0.30 Dart) il segnale è stabile.
  // Le soglie precedenti erano troppo permissive:
  //   rssiVeryClose=-50 → solo 0-30 cm (troppo stretto)
  //   rssiClose=-65     → ok
  //   rssiMedium=-80    → ok
  //
  // Fix: abbassiamo leggermente rssiVeryClose a -55 per catturare anche
  // le situazioni "stesso tavolo", e allarghiamo rssiClose a -68.
  // ─────────────────────────────────────────────────────────────────────────
  static const int rssiVeryClose = -55; // < ~1 m  → "Vicinissimo"
  static const int rssiClose = -68;     // 1–3 m   → "Vicino"
  static const int rssiMedium = -80;    // 3–8 m   → "Medio" (oltre: "Lontano")

  static const int primarySeedColor = 0xFF1D9E75;
  static const int detectionWriteDebounceSeconds = 20;
  static const int nearbyResolveTtlSeconds = 120;
}
