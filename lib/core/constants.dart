/// Costanti centralizzate dell'app.
///
/// Ogni valore "magico" sparso nel codice finisce qui,
/// così i parametri si modificano in un solo punto.
abstract final class AppConstants {
  // ── BLE ──────────────────────────────────────────────────
  /// UUID del service BLE unico di ProxiMeet.
  static const String bleServiceUuid =
      '12345678-1234-1234-1234-123456789abc';

  /// Manufacturer ID usato su Android per trasportare il sessionBleId.
  static const int bleManufacturerId = 0xFF01;

  /// Prefix nel local name BLE: "PM-" + 16 hex chars.
  static const String bleNamePrefix = 'PM-';

  /// Lunghezza del sessionBleId in hex chars (8 bytes = 16 chars).
  static const int sessionBleIdLength = 16;

  // ── Scan / Detection ─────────────────────────────────────
  /// Intervallo tra scan successivi (secondi).
  static const int scanIntervalSeconds = 8;

  /// Durata di ogni singolo scan (secondi).
  static const int scanDurationSeconds = 5;

  /// Dopo quanti secondi senza rilevamento un utente è "stale".
  static const int staleThresholdSeconds = 60;

  /// Ogni quanti secondi rimuovere utenti stale.
  static const int cleanupIntervalSeconds = 15;

  /// Finestra massima (secondi) per gating richieste contatto.
  static const int contactGatingSeconds = 120;

  // ── Heartbeat / Presence ─────────────────────────────────
  /// Intervallo heartbeat presence (secondi).
  static const int heartbeatIntervalSeconds = 30;

  // ── RSSI thresholds ──────────────────────────────────────
  static const int rssiVeryClose = -50;
  static const int rssiClose = -65;
  static const int rssiMedium = -80;

  // ── UI ───────────────────────────────────────────────────
  /// Colore primario seed per il tema Material 3.
  static const int primarySeedColor = 0xFF1D9E75;
}
