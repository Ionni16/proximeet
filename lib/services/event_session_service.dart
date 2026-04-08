import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import '../models/user_model.dart';
import 'ble_advertiser_service.dart';
import 'ble_scanner_service.dart';
import 'presence_heartbeat_service.dart';
import 'nearby_detection_service.dart';

/// Gestisce l'intero lifecycle di un utente dentro un evento:
/// join → BLE + presence + detection → leave/cleanup.
///
/// È il SINGOLO punto di ingresso per entrare/uscire da un evento.
/// Nessun altro codice deve avviare BLE o scrivere presence direttamente.
class EventSessionService {
  static final EventSessionService shared = EventSessionService._();
  EventSessionService._();

  final _db = FirebaseFirestore.instance;

  String? _currentEventId;
  String? _sessionBleId;
  bool _isInEvent = false;

  String? get currentEventId => _currentEventId;
  String? get sessionBleId => _sessionBleId;
  bool get isInEvent => _isInEvent;

  /// Entra in un evento. Esegue in ordine:
  /// 1. Genera sessionBleId univoco
  /// 2. Scrive bleMapping su Firestore (sessionBleId → profilo)
  /// 3. Scrive presence iniziale
  /// 4. Avvia heartbeat
  /// 5. Avvia BLE advertising
  /// 6. Avvia BLE scanning
  /// 7. Avvia NearbyDetectionService
  Future<bool> joinEvent({
    required String eventId,
    required UserModel user,
  }) async {
    // Se già in un evento, esci prima
    if (_isInEvent) {
      await leaveEvent();
    }

    final uid = user.uid;

    // 1. Genera sessionBleId — 16 hex chars (8 bytes), univoco per sessione
    _sessionBleId = const Uuid().v4().replaceAll('-', '').substring(0, 16);
    _currentEventId = eventId;

    print('[SESSION] Join evento $eventId con sessionBleId $_sessionBleId');

    try {
      // 2. Scrivi bleMapping: permette agli scanner di risolvere sessionBleId → utente
      await _db
          .collection('events')
          .doc(eventId)
          .collection('bleMapping')
          .doc(_sessionBleId!)
          .set({
        ...user.toSummary(),
        'sessionBleId': _sessionBleId,
        'joinedAt': FieldValue.serverTimestamp(),
      });

      // 3. Scrivi presence
      await _db
          .collection('events')
          .doc(eventId)
          .collection('presence')
          .doc(uid)
          .set({
        'uid': uid,
        'sessionBleId': _sessionBleId,
        'displayName': user.fullName,
        'avatarURL': user.avatarURL,
        'joinedAt': FieldValue.serverTimestamp(),
        'lastSeen': FieldValue.serverTimestamp(),
        'isActive': true,
      });

      // 4. Avvia heartbeat
      PresenceHeartbeatService.shared.start(eventId: eventId, uid: uid);

      // 5. Avvia BLE advertising
      final advOk = await BleAdvertiserService.shared.start(_sessionBleId!);
      if (!advOk) {
        print('[SESSION] WARNING: Advertising non avviato (device non supportato?)');
      }

      // 6. Avvia BLE scanning
      await BleScannerService.shared.start(mySessionBleId: _sessionBleId!);

      // 7. Avvia nearby detection
      await NearbyDetectionService.shared.start(
        eventId: eventId,
        myUid: uid,
        mySessionBleId: _sessionBleId!,
        scanner: BleScannerService.shared,
      );

      _isInEvent = true;
      print('[SESSION] Join completato con successo');
      return true;
    } catch (e) {
      print('[SESSION] Errore join: $e');
      // Rollback
      await leaveEvent();
      return false;
    }
  }

  /// Esce dall'evento corrente. Ferma tutto e pulisce Firestore.
  Future<void> leaveEvent() async {
    final eventId = _currentEventId;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    print('[SESSION] Leave evento $eventId');

    // 1. Ferma heartbeat
    PresenceHeartbeatService.shared.stop();

    // 2. Ferma BLE
    await BleAdvertiserService.shared.stop();
    await BleScannerService.shared.stop();

    // 3. Ferma nearby detection
    NearbyDetectionService.shared.clear();

    // 4. Aggiorna Firestore
    if (eventId != null && uid != null) {
      try {
        await _db
            .collection('events')
            .doc(eventId)
            .collection('presence')
            .doc(uid)
            .update({
          'isActive': false,
          'leftAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        print('[SESSION] Errore update presence on leave: $e');
      }

      // Rimuovi bleMapping (opzionale, ma pulito)
      if (_sessionBleId != null) {
        try {
          await _db
              .collection('events')
              .doc(eventId)
              .collection('bleMapping')
              .doc(_sessionBleId!)
              .delete();
        } catch (_) {}
      }
    }

    _currentEventId = null;
    _sessionBleId = null;
    _isInEvent = false;
    print('[SESSION] Leave completato');
  }
}
