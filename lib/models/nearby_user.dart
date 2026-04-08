/// Utente rilevato via BLE nelle vicinanze.
class NearbyUser {
  final String uid;
  final String displayName;
  final String company;
  final String role;
  final String avatarURL;
  final int rssi;
  final DateTime lastSeen;

  NearbyUser({
    required this.uid,
    required this.displayName,
    required this.company,
    required this.role,
    required this.avatarURL,
    required this.rssi,
    required this.lastSeen,
  });

  String get firstName => displayName.split(' ').first;

  /// Distanza approssimativa leggibile
  String get distanceLabel {
    if (rssi >= -50) return 'Vicinissimo';
    if (rssi >= -65) return 'Vicino';
    if (rssi >= -80) return 'Medio';
    return 'Lontano';
  }

  /// Raggio proporzionale per il radar (0.0 – 1.0)
  double get radarRadius {
    if (rssi >= -50) return 0.25;
    if (rssi >= -65) return 0.50;
    if (rssi >= -80) return 0.75;
    return 0.90;
  }

  /// True se la detection è più vecchia di [seconds]
  bool isStale({int seconds = 60}) {
    return DateTime.now().difference(lastSeen).inSeconds > seconds;
  }
}

/// Rilevazione BLE grezza, prima del resolve verso profilo utente.
class RawBleDetection {
  final String sessionBleId;
  final int rssi;
  final DateTime timestamp;

  RawBleDetection({
    required this.sessionBleId,
    required this.rssi,
    required this.timestamp,
  });
}
