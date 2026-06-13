import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/constants.dart';
import '../core/logger.dart';

/// Manda un segnale "sono ancora qui" a intervalli regolari su Firestore.
///
/// Ogni battito aggiorna due cose:
///   1. presence/{uid}.lastSeen → tiene viva la presenza all'evento;
///   2. proximityTokens/{token}.expiresAt → rinnova la scadenza del token
///      BLE, così il job cleanupExpiredProximityTokens non lo elimina
///      mentre l'utente è ancora attivo.
///
/// Quando l'app viene chiusa il battito si ferma: presence diventa stale
/// (cleanupStalePresence) e il token scade (cleanup token).
///
/// Singleton: usa PresenceHeartbeatService.instance.
class PresenceHeartbeatService {
  PresenceHeartbeatService._();
  static final PresenceHeartbeatService instance =
      PresenceHeartbeatService._();

  static const _tag = 'HEARTBEAT';

  Timer? _timer;
  String? _eventId;
  String? _uid;
  String? _proximityToken;
  int _tokenTtlSeconds = AppConstants.proximityTokenTtlSeconds;

  bool get isRunning => _timer != null;

  void start({
    required String eventId,
    required String uid,
    String? proximityToken,
    int intervalSeconds = AppConstants.heartbeatIntervalSeconds,
    int tokenTtlSeconds = AppConstants.proximityTokenTtlSeconds,
  }) {
    if (_timer != null &&
        _eventId == eventId &&
        _uid == uid &&
        _proximityToken == proximityToken) {
      return;
    }
    stop();

    _eventId = eventId;
    _uid = uid;
    _proximityToken = proximityToken;
    _tokenTtlSeconds = tokenTtlSeconds;

    _beat();

    _timer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => _beat(),
    );

    Log.d(_tag, 'Avviato per evento $eventId (ogni ${intervalSeconds}s)');
  }

  void _beat() {
    final eventId = _eventId;
    final uid = _uid;
    if (eventId == null || uid == null) return;

    final eventRef =
        FirebaseFirestore.instance.collection('events').doc(eventId);

    // 1) Presenza viva. Un fallimento non deve mai propagarsi dal timer.
    eventRef.collection('presence').doc(uid).set({
      'lastSeen': FieldValue.serverTimestamp(),
      'isActive': true,
    }, SetOptions(merge: true)).catchError((Object e) {
      Log.w(_tag, 'Heartbeat presence fallito: $e');
    });

    // 2) Rinnovo scadenza del proximity token (se presente).
    final token = _proximityToken;
    if (token != null && token.isNotEmpty) {
      final expiresAt = Timestamp.fromDate(
        DateTime.now().add(Duration(seconds: _tokenTtlSeconds)),
      );
      eventRef.collection('proximityTokens').doc(token).set({
        'expiresAt': expiresAt,
        'updatedAt': FieldValue.serverTimestamp(),
        'active': true,
      }, SetOptions(merge: true)).catchError((Object e) {
        Log.w(_tag, 'Heartbeat refresh token fallito: $e');
      });
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_eventId != null) {
      Log.d(_tag, 'Fermato per evento $_eventId');
    }
    _eventId = null;
    _uid = null;
    _proximityToken = null;
  }
}
