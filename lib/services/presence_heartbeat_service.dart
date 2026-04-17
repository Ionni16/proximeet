import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/constants.dart';
import '../core/logger.dart';

/// Aggiorna periodicamente `lastSeen` nella presence.
///
/// Singleton: usa [PresenceHeartbeatService.instance].
class PresenceHeartbeatService {
  PresenceHeartbeatService._();
  static final PresenceHeartbeatService instance =
      PresenceHeartbeatService._();

  Timer? _timer;
  String? _eventId;
  String? _uid;

  bool get isRunning => _timer != null;

  void start({
    required String eventId,
    required String uid,
    int intervalSeconds = AppConstants.heartbeatIntervalSeconds,
  }) {
    if (_timer != null && _eventId == eventId && _uid == uid) return;
    stop();

    _eventId = eventId;
    _uid = uid;

    _beat();

    _timer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => _beat(),
    );

    Log.d('HEARTBEAT', 'Avviato per evento $eventId (ogni ${intervalSeconds}s)');
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

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_eventId != null) {
      Log.d('HEARTBEAT', 'Fermato per evento $_eventId');
    }
    _eventId = null;
    _uid = null;
  }
}
