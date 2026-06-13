import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/constants.dart';
import '../models/connection_model.dart';
import '../models/event_model.dart';
import '../models/user_model.dart';
import 'event_session_service.dart';
import 'nearby_detection_service.dart';

/// Punto unico di accesso ai dati dell'app.
///
/// Letture: stream/query Firestore dirette (consentite dalle Rules).
/// Scritture cross-utente (richieste di contatto, wallet): SOLO tramite
/// Cloud Functions, che verificano server-side prossimità, presenza
/// all'evento e identità. Vedi functions/index.js e firestore.rules.
///
/// Singleton: usa sempre FirestoreService.instance.
class FirestoreService {
  FirestoreService._();
  static final FirestoreService instance = FirestoreService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  // ── UTENTI ──────────────────────────────────────────────

  Future<UserModel?> getUserByUid(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;

    final data = doc.data();
    if (data == null) return null;

    // Usiamo il doc ID come uid perché alcuni profili vecchi non ce l'hanno nel campo.
    return UserModel.fromMap({
      ...data,
      'uid': (data['uid'] ?? uid).toString(),
    });
  }

  // ── EVENTI ──────────────────────────────────────────────

  Stream<List<EventModel>> listenToActiveEvents() {
    return _db
        .collection('events')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => EventModel.fromMap(d.id, d.data()))
              .toList(),
        );
  }

  Future<EventModel?> getEvent(String eventId) async {
    final doc = await _db.collection('events').doc(eventId).get();
    if (!doc.exists) return null;

    final data = doc.data();
    if (data == null) return null;

    return EventModel.fromMap(doc.id, data);
  }

  /// Stream con il numero di utenti attivi in questo momento nell'evento.
  Stream<int> listenToActiveCount(String eventId) {
    return _db
        .collection('events')
        .doc(eventId)
        .collection('presence')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map((snap) => snap.docs.length);
  }

  // ── RICHIESTE CONTATTO ──────────────────────────────────

  /// Manda una richiesta di scambio biglietto tramite la Cloud Function
  /// `sendConnectionRequest`.
  ///
  /// Il server verifica in modo autorevole che:
  ///  - entrambi siano presenti e attivi nell'evento (heartbeat recente);
  ///  - per le richieste BLE esista una detection recente con RSSI sufficiente;
  ///  - non esista già una richiesta pendente/accettata in nessuna direzione.
  ///
  /// I controlli qui sotto servono solo a dare un errore immediato all'utente
  /// nei casi ovvi, senza un round-trip di rete.
  Future<void> sendConnectionRequest(
    String targetUid, {
    bool fromQr = false,
    String? qrEventId,
  }) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) {
      throw Exception('Non autenticato');
    }

    if (targetUid == myUid) {
      throw Exception('Non puoi inviare una richiesta a te stesso');
    }

    final eventId = EventSessionService.instance.currentEventId;
    if (eventId == null) {
      throw Exception('Non sei in nessun evento');
    }

    if (qrEventId != null && qrEventId.isNotEmpty && qrEventId != eventId) {
      throw Exception('QR di un altro evento');
    }

    // Pre-check locale per le richieste BLE: se il peer non è in lista nearby
    // evitiamo la chiamata di rete. La verifica vera (lettura della detection
    // su Firestore, finestra temporale, soglia RSSI) la fa comunque il server.
    if (!fromQr &&
        !NearbyDetectionService.instance.isRecentlyDetected(
          targetUid,
          maxSeconds: AppConstants.contactGatingSeconds,
        )) {
      throw Exception('Utente non rilevato nelle vicinanze');
    }

    await _call('sendConnectionRequest', {
      'targetUid': targetUid,
      'eventId': eventId,
      'source': fromQr ? 'qr' : 'ble',
    });
  }

  /// Accetta o rifiuta una richiesta tramite la Cloud Function
  /// `respondConnectionRequest`.
  ///
  /// Il server verifica che il chiamante sia il destinatario, aggiorna lo
  /// stato in transazione e — se accettata — scrive ENTRAMBI i wallet in un
  /// batch atomico con privilegi admin. Il client non scrive mai nel wallet
  /// di un altro utente.
  Future<void> respondToRequest(String requestId, bool accepted) async {
    await _call('respondConnectionRequest', {
      'requestId': requestId,
      'accepted': accepted,
    });
  }

  Stream<List<ConnectionRequest>> listenToIncomingRequests() {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return Stream.value([]);

    return _db
        .collection('connectionRequests')
        .where('receiverUid', isEqualTo: myUid)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => ConnectionRequest.fromMap(d.id, d.data()))
              .toList(),
        );
  }

  // ── WALLET ──────────────────────────────────────────────

  /// Stream del wallet del corrente utente.
  ///
  /// Niente più "idratazione" N+1 dei profili a ogni snapshot: i dati
  /// denormalizzati nei contatti vengono mantenuti aggiornati dal trigger
  /// server-side `syncProfileToWallets` quando un profilo cambia.
  Stream<List<WalletContact>> listenToWallet() {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return Stream.value([]);

    return _db
        .collection('connections')
        .doc(myUid)
        .collection('contacts')
        .orderBy('connectedAt', descending: true)
        .snapshots()
        .map(
          (snap) =>
              snap.docs.map((d) => WalletContact.fromMap(d.data())).toList(),
        );
  }

  // ── HELPER ──────────────────────────────────────────────

  /// Invoca una callable e converte gli errori in [Exception] con il
  /// messaggio leggibile prodotto dal server, così le snackbar esistenti
  /// continuano a mostrare testi sensati senza cambiare le schermate.
  Future<void> _call(String name, Map<String, dynamic> payload) async {
    try {
      await _functions.httpsCallable(name).call<dynamic>(payload);
    } on FirebaseFunctionsException catch (e) {
      final message = (e.message ?? '').trim();
      throw Exception(message.isNotEmpty ? message : 'Operazione non riuscita');
    }
  }
}
