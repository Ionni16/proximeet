abstract final class AppConstants {
  // ── BLE ──────────────────────────────────────────────────
  /// Prefix nel local name BLE: "PM-" + 16 hex chars.
  static const String bleNamePrefix = 'PM-';

  /// Lunghezza del sessionBleId in hex chars (8 bytes = 16 chars).
  static const int sessionBleIdLength = 16;

  // ── Scan / Detection ─────────────────────────────────────
  static const int scanIntervalSeconds = 8;
  static const int scanDurationSeconds = 5;
  static const int staleThresholdSeconds = 60;
  static const int cleanupIntervalSeconds = 15;
  static const int contactGatingSeconds = 120;

  // ── Heartbeat / Presence ─────────────────────────────────
  static const int heartbeatIntervalSeconds = 30;

  // ── RSSI thresholds ──────────────────────────────────────
  static const int rssiVeryClose = -50;
  static const int rssiClose = -65;
  static const int rssiMedium = -80;

  // ── UI ───────────────────────────────────────────────────
  static const int primarySeedColor = 0xFF1D9E75;

  static const int detectionWriteDebounceSeconds = 20;
  static const int nearbyResolveTtlSeconds = 120;
}