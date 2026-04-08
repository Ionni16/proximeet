import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/nearby_user.dart';
import 'ble_scanner_service.dart';

/// Dati cachati del mapping sessionBleId → profilo utente.
class _CachedProfile {
  final String uid;
  final String displayName;
  final String company;
  final String role;
  final String avatarURL;

  _CachedProfile({
    required this.uid,
    required this.displayName,
    required this.company,
    required this.role,
    required this.avatarURL,
  });
}

/// Orchestratore tra BLE scanner e UI.
///
/// 1. Ascolta [BleScannerService.detections] (raw BLE detections)
/// 2. Risolve sessionBleId → uid + profilo (cache locale + Firestore bleMapping)
/// 3. Filtra duplicati e stale
/// 4. Scrive detections su Firestore (per gating richieste contatto)
/// 5. Emette [Stream<List<NearbyUser>>] per la UI radar/lista
class NearbyDetectionService {
  static final NearbyDetectionService shared = NearbyDetectionService._();
  NearbyDetectionService._();

  final _db = FirebaseFirestore.instance;

  /// Cache locale: sessionBleId → profilo. Evita query Firestore ripetute.
  final Map<String, _CachedProfile> _resolveCache = {};

  /// Stato corrente degli utenti nearby: uid → NearbyUser
  final Map<String, NearbyUser> _nearbyMap = {};

  /// Stream esposto alla UI
  final _nearbyController = StreamController<List<NearbyUser>>.broadcast();
  Stream<List<NearbyUser>> get nearbyStream => _nearbyController.stream;

  /// Snapshot corrente (per accesso sincrono)
  List<NearbyUser> get currentNearby => _nearbyMap.values.toList()
    ..sort((a, b) => b.rssi.compareTo(a.rssi)); // più vicino prima

  StreamSubscription? _scanSub;
  Timer? _cleanupTimer;
  String? _eventId;
  String? _myUid;
  String? _mySessionBleId;

  bool get isRunning => _scanSub != null;

  /// Avvia il servizio. Precarica la cache dal bleMapping di Firestore.
  Future<void> start({
    required String eventId,
    required String myUid,
    required String mySessionBleId,
    required BleScannerService scanner,
  }) async {
    if (_scanSub != null) return;

    _eventId = eventId;
    _myUid = myUid;
    _mySessionBleId = mySessionBleId;

    // Precarica mapping esistenti
    await _preloadCache(eventId);

    // Ascolta raw detections dallo scanner
    _scanSub = scanner.detections.listen(_onRawDetection);

    // Cleanup periodico: rimuovi utenti stale ogni 15s
    _cleanupTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _removeStale(),
    );

    print('[NEARBY] Avviato per evento $eventId');
  }

  /// Precarica tutti i bleMapping dell'evento nella cache locale.
  Future<void> _preloadCache(String eventId) async {
    try {
      final snap = await _db
          .collection('events')
          .doc(eventId)
          .collection('bleMapping')
          .get();

      for (final doc in snap.docs) {
        final data = doc.data();
        _resolveCache[doc.id] = _CachedProfile(
          uid: data['uid'] ?? '',
          displayName: data['displayName'] ?? '',
          company: data['company'] ?? '',
          role: data['role'] ?? '',
          avatarURL: data['avatarURL'] ?? '',
        );
      }
      print('[NEARBY] Cache precaricata: ${_resolveCache.length} utenti');
    } catch (e) {
      print('[NEARBY] Errore preload cache: $e');
    }
  }

  /// Gestisci una detection grezza.
  Future<void> _onRawDetection(RawBleDetection raw) async {
    // Ignora me stesso
    if (raw.sessionBleId == _mySessionBleId) return;

    // Risolvi sessionBleId → profilo
    final profile = await _resolve(raw.sessionBleId);
    if (profile == null) return;
    if (profile.uid == _myUid) return; // doppio check

    // Aggiorna mappa nearby
    _nearbyMap[profile.uid] = NearbyUser(
      uid: profile.uid,
      displayName: profile.displayName,
      company: profile.company,
      role: profile.role,
      avatarURL: profile.avatarURL,
      rssi: raw.rssi,
      lastSeen: raw.timestamp,
    );

    // Scrivi detection su Firestore (per gating richieste contatto)
    _writeDetection(profile.uid, raw.rssi);

    // Emetti aggiornamento
    _emit();
  }

  /// Risolvi sessionBleId → profilo. Cache first, poi Firestore.
  Future<_CachedProfile?> _resolve(String sessionBleId) async {
    // Cache hit
    if (_resolveCache.containsKey(sessionBleId)) {
      return _resolveCache[sessionBleId];
    }

    // Firestore lookup
    if (_eventId == null) return null;
    try {
      final doc = await _db
          .collection('events')
          .doc(_eventId!)
          .collection('bleMapping')
          .doc(sessionBleId)
          .get();

      if (!doc.exists) return null;
      final data = doc.data()!;
      final profile = _CachedProfile(
        uid: data['uid'] ?? '',
        displayName: data['displayName'] ?? '',
        company: data['company'] ?? '',
        role: data['role'] ?? '',
        avatarURL: data['avatarURL'] ?? '',
      );
      _resolveCache[sessionBleId] = profile;
      return profile;
    } catch (e) {
      print('[NEARBY] Errore resolve $sessionBleId: $e');
      return null;
    }
  }

  /// Scrivi/aggiorna detection su Firestore.
  void _writeDetection(String detectedUid, int rssi) {
    if (_eventId == null || _myUid == null) return;

    _db
        .collection('events')
        .doc(_eventId!)
        .collection('detections')
        .doc(_myUid!)
        .collection('nearby')
        .doc(detectedUid)
        .set({
      'rssi': rssi,
      'lastSeen': FieldValue.serverTimestamp(),
    });
  }

  /// Rimuovi utenti non rilevati da più di 60 secondi.
  void _removeStale() {
    final staleUids = _nearbyMap.entries
        .where((e) => e.value.isStale(seconds: 60))
        .map((e) => e.key)
        .toList();

    if (staleUids.isEmpty) return;

    for (final uid in staleUids) {
      _nearbyMap.remove(uid);
    }
    _emit();
    print('[NEARBY] Rimossi ${staleUids.length} utenti stale');
  }

  /// Emetti la lista corrente.
  void _emit() {
    if (!_nearbyController.isClosed) {
      _nearbyController.add(currentNearby);
    }
  }

  /// Verifica se un utente è stato rilevato di recente (per gating richieste).
  bool isRecentlyDetected(String uid, {int maxSeconds = 120}) {
    final user = _nearbyMap[uid];
    if (user == null) return false;
    return !user.isStale(seconds: maxSeconds);
  }

  /// Ferma e pulisci tutto.
  void clear() {
    _scanSub?.cancel();
    _scanSub = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _nearbyMap.clear();
    _resolveCache.clear();
    _eventId = null;
    _myUid = null;
    _mySessionBleId = null;
    _emit();
    print('[NEARBY] Servizio fermato e cache pulita');
  }

  void dispose() {
    clear();
    _nearbyController.close();
  }
}
