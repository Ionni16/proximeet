import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Aggiorna periodicamente il campo `lastSeen` nella presence dell'utente
/// per segnalare che è ancora attivo nell'evento.
///
/// Senza heartbeat, il lastSeen viene scritto una sola volta al join
/// e non sappiamo se l'utente è ancora presente.
class PresenceHeartbeatService {
  static final PresenceHeartbeatService shared = PresenceHeartbeatService._();
  PresenceHeartbeatService._();

  Timer? _timer;
  String? _eventId;
  String? _uid;

  bool get isRunning => _timer != null;

  /// Avvia heartbeat ogni [intervalSeconds] (default 30s).
  void start({
    required String eventId,
    required String uid,
    int intervalSeconds = 30,
  }) {
    // Se già attivo per lo stesso evento, skip
    if (_timer != null && _eventId == eventId && _uid == uid) return;

    // Se attivo per un altro evento, ferma prima
    stop();

    _eventId = eventId;
    _uid = uid;

    // Beat immediato
    _beat();

    // Beat periodico
    _timer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => _beat(),
    );

    print('[HEARTBEAT] Avviato per evento $eventId (ogni ${intervalSeconds}s)');
  }

  void _beat() {
    if (_eventId == null || _uid == null) return;

    FirebaseFirestore.instance
        .collection('events')
        .doc(_eventId!)
        .collection('presence')
        .doc(_uid!)
        .set({
      'lastSeen': FieldValue.serverTimestamp(),
      'isActive': true,
    }, SetOptions(merge: true));
  }

  /// Ferma heartbeat.
  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_eventId != null) {
      print('[HEARTBEAT] Fermato per evento $_eventId');
    }
    _eventId = null;
    _uid = null;
  }
}
