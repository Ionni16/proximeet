abstract final class AppConstants {
  // ── BLE: identità protocollo ──────────────────────────────────────────────

  /// Lunghezza del sessionBleId come stringa hex (8 byte = 16 chars).
  static const int sessionBleIdLength = 16;

  /// Signature suffix che identifica un advertisement ProxiMeet.
  /// Sono 16 hex chars (8 byte) e occupano la "metà bassa" dell'UUID 128-bit:
  ///   FAAB    = retro-compat con il vecchio service UUID 16-bit (0xFAAB)
  ///   50524F58494D = ASCII "PROXIM"
  /// Lo scanner riconosce un UUID ProxiMeet se finisce con questa signature.
  static const String bleSignatureSuffix = 'FAAB50524F58494D';

  /// Vecchio service UUID 16-bit ProxiMeet — mantenuto come fallback per
  /// scanner che parsano ancora il formato legacy (manufacturerData/localName).
  static const String legacyBleServiceUuid =
      '0000FAAB-0000-1000-8000-00805F9B34FB';

  /// Vecchio prefisso del localName iOS — riconosciuto come fallback in scan.
  static const String legacyBleNamePrefix = 'PM-';

  /// Vecchio company ID nel manufacturer data — riconosciuto come fallback.
  static const int legacyBleManufacturerId = 0xFFFF;

  /// Costruisce l'UUID 128-bit ProxiMeet codificando il sessionBleId.
  ///
  /// Schema:
  ///   XXXXXXXX-XXXX-XXXX-FAAB-50524F58494D
  ///   └─ 8 byte sessionBleId ─┘└── 8 byte signature ──┘
  ///
  /// Esempio:
  ///   sessionBleId = "669f6d6c543a4c22"
  ///   UUID         = "669f6d6c-543a-4c22-faab-50524f58494d"
  ///
  /// L'UUID viaggia nel main advertising packet (18 byte) ed è visibile a
  /// tutti gli scanner BLE — su qualunque OS, anche quando localName e
  /// manufacturerData vengono filtrati o strippati dal sistema.
  static String buildSessionUuid(String sessionBleId) {
    assert(
      sessionBleId.length == sessionBleIdLength,
      'sessionBleId deve essere $sessionBleIdLength hex chars',
    );
    final id = sessionBleId.toLowerCase();
    final sig = bleSignatureSuffix.toLowerCase();
    // Formato UUID: 8-4-4-4-12 hex chars.
    return '${id.substring(0, 8)}-'
        '${id.substring(8, 12)}-'
        '${id.substring(12, 16)}-'
        '${sig.substring(0, 4)}-'
        '${sig.substring(4, 16)}';
  }

  /// Estrae il sessionBleId da un UUID se è un advertisement ProxiMeet.
  /// Ritorna null se l'UUID non ha la signature ProxiMeet.
  ///
  /// Robusto a: case-insensitive, presenza/assenza di hyphens.
  static String? extractSessionBleIdFromUuid(String uuid) {
    final clean = uuid.replaceAll('-', '').toLowerCase();
    if (clean.length != 32) return null;

    final sig = bleSignatureSuffix.toLowerCase();
    if (!clean.endsWith(sig)) return null;

    final candidate = clean.substring(0, sessionBleIdLength);
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(candidate)) return null;
    return candidate;
  }

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
