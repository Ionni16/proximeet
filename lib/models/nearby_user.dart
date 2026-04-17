import '../core/constants.dart';

/// Utente rilevato via BLE nelle vicinanze.
///
/// Contiene sia i dati BLE (rssi, lastSeen) che i dati profilo
/// risolti dal bleMapping Firestore.
class NearbyUser {
  final String uid;
  final String displayName;
  final String company;
  final String role;
  final String avatarURL;
  final String bio;
  final String email;
  final String linkedin;
  final String phone;
  final int rssi;
  final DateTime lastSeen;

  NearbyUser({
    required this.uid,
    required this.displayName,
    required this.company,
    required this.role,
    required this.avatarURL,
    this.bio = '',
    this.email = '',
    this.linkedin = '',
    this.phone = '',
    required this.rssi,
    required this.lastSeen,
  });

  String get firstName => displayName.split(' ').first;

  /// Distanza approssimativa leggibile.
  String get distanceLabel {
    if (rssi >= AppConstants.rssiVeryClose) return 'Vicinissimo';
    if (rssi >= AppConstants.rssiClose) return 'Vicino';
    if (rssi >= AppConstants.rssiMedium) return 'Medio';
    return 'Lontano';
  }

  /// Icona distanza.
  String get distanceEmoji {
    if (rssi >= AppConstants.rssiVeryClose) return '📍';
    if (rssi >= AppConstants.rssiClose) return '📡';
    if (rssi >= AppConstants.rssiMedium) return '📶';
    return '🔭';
  }

  /// Raggio proporzionale per il radar (0.0 – 1.0).
  double get radarRadius {
    if (rssi >= AppConstants.rssiVeryClose) return 0.25;
    if (rssi >= AppConstants.rssiClose) return 0.50;
    if (rssi >= AppConstants.rssiMedium) return 0.75;
    return 0.90;
  }

  /// True se la detection è più vecchia di [seconds].
  bool isStale({int seconds = AppConstants.staleThresholdSeconds}) {
    return DateTime.now().difference(lastSeen).inSeconds > seconds;
  }

  /// Quanto tempo fa è stato rilevato, in formato leggibile.
  String get lastSeenLabel {
    final diff = DateTime.now().difference(lastSeen).inSeconds;
    if (diff < 5) return 'Adesso';
    if (diff < 60) return '${diff}s fa';
    return '${diff ~/ 60}m fa';
  }

  /// True se ha almeno un campo social compilato.
  bool get hasSocials =>
      linkedin.isNotEmpty || email.isNotEmpty || phone.isNotEmpty;
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
