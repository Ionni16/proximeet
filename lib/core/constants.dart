abstract final class AppConstants {
  // ── BLE: identità protocollo ──────────────────────────────────────────────

  /// Prefisso nel localName iOS: "PM-" + [sessionBleIdLength] hex chars.
  static const String bleNamePrefix = 'PM-';

  /// Lunghezza del sessionBleId come stringa hex (8 byte = 16 chars).
  static const int sessionBleIdLength = 16;

  /// Service UUID ProxiMeet — 16-bit Bluetooth base UUID (0xFAAB).
  ///
  /// Ruolo:
  ///   Android advertiser → incluso nel main packet, occupa 4 byte.
  ///     Grazie ad esso, il manufacturer data rimane nel main packet
  ///     invece di finire nello scan response.
  ///   iOS scanner → withServices:[bleServiceUuid] per rilevazione
  ///     affidabile e supporto background (Core Bluetooth lo richiede).
  ///   iOS advertiser → dichiarato in CBAdvertisementData, consente
  ///     al peer Android di filtrare/identificare il device.
  ///
  /// Budget Android main packet con questo UUID:
  ///   FLAGS(3) + serviceUuid16(4) + manufacturerSpecific(10) = 17B ≤ 31B ✓
  static const String bleServiceUuid = '0000FAAB-0000-1000-8000-00805F9B34FB';

  /// Company ID usato nel campo Manufacturer Specific Data (Android).
  /// 0xFFFF = non assegnato da Bluetooth SIG, usato per app custom/testing.
  static const int bleManufacturerId = 0xFFFF;

  // ── Scan / Detection ─────────────────────────────────────────────────────
  static const int scanIntervalSeconds = 8;
  static const int scanDurationSeconds = 5;
  static const int staleThresholdSeconds = 60;
  static const int cleanupIntervalSeconds = 15;
  static const int contactGatingSeconds = 120;

  // ── Heartbeat / Presence ─────────────────────────────────────────────────
  static const int heartbeatIntervalSeconds = 30;

  // ── RSSI thresholds ──────────────────────────────────────────────────────
  static const int rssiVeryClose = -50;
  static const int rssiClose = -65;
  static const int rssiMedium = -80;

  // ── UI ───────────────────────────────────────────────────────────────────
  static const int primarySeedColor = 0xFF1D9E75;

  static const int detectionWriteDebounceSeconds = 20;
  static const int nearbyResolveTtlSeconds = 120;
}
