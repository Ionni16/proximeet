import '../core/constants.dart';

/// Persona rilevata via BLE nelle vicinanze.
/// Ha sia i dati tecnici BLE (rssi, lastSeen) che il profilo
/// caricato da Firestore tramite il token temporaneo.
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

  /// Etichetta testuale della distanza stimata in base all'RSSI.
  String get distanceLabel {
    if (rssi >= AppConstants.rssiVeryClose) return 'Vicinissimo';
    if (rssi >= AppConstants.rssiClose) return 'Vicino';
    if (rssi >= AppConstants.rssiMedium) return 'Medio';
    return 'Lontano';
  }

  /// Icona che rappresenta la forza del segnale BLE.
  String get distanceEmoji {
    if (rssi >= AppConstants.rssiVeryClose) return '📍';
    if (rssi >= AppConstants.rssiClose) return '📡';
    if (rssi >= AppConstants.rssiMedium) return '📶';
    return '🔭';
  }

  /// Dove posizionare l'utente sul radar: 0 = vicino, 1 = bordo.
  double get radarRadius {
    if (rssi >= AppConstants.rssiVeryClose) return 0.25;
    if (rssi >= AppConstants.rssiClose) return 0.50;
    if (rssi >= AppConstants.rssiMedium) return 0.75;
    return 0.90;
  }

  /// Torna true se non riceviamo segnale da questo utente da troppo tempo.
  bool isStale({int seconds = AppConstants.staleThresholdSeconds}) {
    return DateTime.now().difference(lastSeen).inSeconds > seconds;
  }

  /// Stringa leggibile di quando è stato visto l'ultima volta (es. "2s fa").
  String get lastSeenLabel {
    final diff = DateTime.now().difference(lastSeen).inSeconds;
    if (diff < 5) return 'Adesso';
    if (diff < 60) return '${diff}s fa';
    return '${diff ~/ 60}m fa';
  }

  /// True se l'utente ha almeno un contatto social inserito.
  bool get hasSocials =>
      linkedin.isNotEmpty || email.isNotEmpty || phone.isNotEmpty;
}

/// Dato grezzo che arriva dal BLE, prima di sapere a chi appartiene.
class RawBleDetection {
  /// Token temporaneo letto dalla characteristic GATT del peer.
  /// Si chiama ancora sessionBleId per non rompere il codice che lo usa.
  final String sessionBleId;
  final int rssi;
  final DateTime timestamp;
  final String transport;

  RawBleDetection({
    required this.sessionBleId,
    required this.rssi,
    required this.timestamp,
    this.transport = 'ble_gatt',
  });
}
