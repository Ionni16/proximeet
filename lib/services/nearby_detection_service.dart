import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../core/parsing.dart';
import '../models/nearby_user.dart';
import 'ble_scanner_service.dart';

/// Profilo utente tenuto in memoria dopo averlo letto da Firestore.
class _CachedProfile {
  final String uid;
  final String displayName;
  final String company;
  final String role;
  final String avatarURL;
  final String bio;

  _CachedProfile({
    required this.uid,
    required this.displayName,
    required this.company,
    required this.role,
    required this.avatarURL,
    this.bio = '',
  });

  factory _CachedProfile.fromData(Map<String, dynamic> data) {
    return _CachedProfile(
      uid: parseString(data['uid']),
      displayName: parseString(data['displayName']),
      company: parseString(data['company']),
      role: parseString(data['role']),
      avatarURL: parseString(data['avatarURL']),
      bio: parseString(data['bio']),
    );
  }
}

/// Collega lo scanner BLE con la UI: sente le detection, risolve il token
/// per capire chi è il peer, liscia l'RSSI e aggiorna la lista nella UI.
///
/// Passi:
/// 1. Ascolta BleScannerService.detections
/// 2. Risolve il token → uid + profilo (solo token attivi e non scaduti)
/// 3. Liscia l'RSSI con EWMA (α=0.3)
/// 4. Filtra duplicati e entry troppo vecchie
/// 5. Scrive la detection su Firestore (usata per il gating contatti)
/// 6. Emette Stream<List<NearbyUser>> alla UI
///
/// Singleton: usa NearbyDetectionService.instance.
class NearbyDetectionService {
  NearbyDetectionService._();
  static final NearbyDetectionService instance = NearbyDetectionService._();

  static const _tag = 'NEARBY';

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  final Map<String, _CachedProfile> _resolveCache = {};
  final Map<String, NearbyUser> _nearbyMap = {};
  final Map<String, DateTime> _lastDetectionWriteAt = {};

  // Mappa uid → token corrente del peer. Serve a ripulire _rssiSmoothed
  // (che è keyed by token) quando un utente diventa stale, evitando il leak.
  final Map<String, String> _tokenByUid = {};

  // Lisciatura RSSI lato Dart con media mobile esponenziale (EWMA).
  // È un secondo filtro: il plugin nativo di solito ha già liscio il valore,
  // ma questo copre il caso in cui non lo faccia (vecchie build o test).
  // α=0.3 perché il nativo ha già attenuato i picchi, possiamo essere più reattivi.
  final Map<String, double> _rssiSmoothed = {};
  static const double _ewmaAlpha = 0.3;

  // Non emettiamo un aggiornamento per lo stesso utente più spesso di 900ms
  // per non inondare la UI di rebuild continue.
  final Map<String, DateTime> _lastEmitForUid = {};
  static const int _minEmitIntervalMs = 900;
  // ─────────────────────────────────────────────────────────────────────────

  final StreamController<List<NearbyUser>> _nearbyController =
      StreamController<List<NearbyUser>>.broadcast();

  Stream<List<NearbyUser>> get nearbyStream => _nearbyController.stream;

  List<NearbyUser> get currentNearby {
    final list = _nearbyMap.values.toList();
    list.sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  StreamSubscription<RawBleDetection>? _scanSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _mappingSub;
  Timer? _cleanupTimer;

  String? _eventId;
  String? _myUid;
  String? _mySessionBleId;

  bool get isRunning => _scanSub != null;

  /// True se il documento token è utilizzabile: non disattivato e non scaduto.
  /// I peer che hanno fatto leave (active=false) o il cui token è scaduto
  /// non devono comparire come "vicini".
  bool _isTokenUsable(Map<String, dynamic> data) {
    if (data['active'] == false) return false;
    final expiresAt = parseDateTime(data['expiresAt']);
    if (expiresAt != null && expiresAt.isBefore(DateTime.now())) return false;
    return true;
  }

  Future<void> start({
    required String eventId,
    required String myUid,
    required String mySessionBleId,
    required BleScannerService scanner,
  }) async {
    if (_scanSub != null) {
      if (_eventId == eventId &&
          _myUid == myUid &&
          _mySessionBleId == mySessionBleId) {
        return;
      }
      clear();
    }

    _eventId = eventId;
    _myUid = myUid;
    _mySessionBleId = mySessionBleId;

    await _preloadCache(eventId);

    _scanSub = scanner.detections.listen(
      _onRawDetection,
      onError: (Object e) => Log.e(_tag, 'Errore stream detections', e),
    );

    _mappingSub = _db
        .collection('events')
        .doc(eventId)
        .collection('proximityTokens')
        .snapshots()
        .listen(
          _onMappingChange,
          onError: (Object e) => Log.e(_tag, 'Errore stream proximityTokens', e),
        );

    _cleanupTimer = Timer.periodic(
      const Duration(seconds: AppConstants.cleanupIntervalSeconds),
      (_) => _removeStale(),
    );

    _emit();
    Log.d(_tag, 'Avviato per evento $eventId');
  }

  Future<void> _preloadCache(String eventId) async {
    try {
      final snap = await _db
          .collection('events')
          .doc(eventId)
          .collection('proximityTokens')
          .get();

      var loaded = 0;
      for (final doc in snap.docs) {
        final data = doc.data();
        // Saltiamo i token non più validi (leave / scaduti).
        if (!_isTokenUsable(data)) continue;
        _resolveCache[doc.id] = _CachedProfile.fromData(data);
        loaded++;
      }

      Log.d(_tag, 'Cache precaricata: $loaded utenti attivi');
    } catch (e) {
      Log.e(_tag, 'Errore preload cache', e);
    }
  }

  /// Reagisce solo ai documenti effettivamente cambiati (docChanges) invece
  /// di riscorrere l'intera collezione a ogni snapshot.
  void _onMappingChange(QuerySnapshot<Map<String, dynamic>> snap) {
    bool anyChange = false;

    for (final change in snap.docChanges) {
      final doc = change.doc;
      final data = doc.data() ?? <String, dynamic>{};
      final token = doc.id;

      // Rimozione, disattivazione o scadenza → trattiamo come "uscito".
      if (change.type == DocumentChangeType.removed || !_isTokenUsable(data)) {
        final removed = _resolveCache.remove(token);
        final uid = removed?.uid ?? parseString(data['uid']);
        if (uid.isNotEmpty && _nearbyMap.remove(uid) != null) {
          _tokenByUid.remove(uid);
          _rssiSmoothed.remove(token);
          _lastDetectionWriteAt.remove(uid);
          _lastEmitForUid.remove(uid);
          anyChange = true;
        }
        continue;
      }

      final newProfile = _CachedProfile.fromData(data);
      _resolveCache[token] = newProfile;

      // Se il peer è già in lista, aggiorniamo i suoi dati di profilo
      // mantenendo RSSI e lastSeen correnti.
      final existing = _nearbyMap[newProfile.uid];
      if (existing != null) {
        _nearbyMap[newProfile.uid] = NearbyUser(
          uid: newProfile.uid,
          displayName: newProfile.displayName,
          company: newProfile.company,
          role: newProfile.role,
          avatarURL: newProfile.avatarURL,
          bio: newProfile.bio,
          email: '',
          linkedin: '',
          phone: '',
          rssi: existing.rssi,
          lastSeen: existing.lastSeen,
        );
        anyChange = true;
      }
    }

    if (anyChange) _emit();
  }

  Future<void> _onRawDetection(RawBleDetection raw) async {
    if (raw.sessionBleId == _mySessionBleId) return;

    // ── EWMA smoothing dart-side ─────────────────────────────────────────
    final prevSmoothed = _rssiSmoothed[raw.sessionBleId];
    final smoothedRssi = prevSmoothed == null
        ? raw.rssi.toDouble()
        : _ewmaAlpha * raw.rssi + (1.0 - _ewmaAlpha) * prevSmoothed;
    _rssiSmoothed[raw.sessionBleId] = smoothedRssi;
    final rssiInt = smoothedRssi.round();
    // ─────────────────────────────────────────────────────────────────────

    final profile = await _resolve(raw.sessionBleId);
    if (profile == null) return;
    if (profile.uid.isEmpty) return;
    if (profile.uid == _myUid) return;

    // Teniamo traccia di quale token appartiene a questo uid, così quando
    // diventa stale possiamo ripulire anche _rssiSmoothed (niente leak).
    _tokenByUid[profile.uid] = raw.sessionBleId;

    // Se abbiamo già mandato un update per questo utente
    // e l'RSSI non è cambiato di più di 3 dBm, saltiamo l'emit.
    final now = DateTime.now();
    final lastEmit = _lastEmitForUid[profile.uid];
    final existing = _nearbyMap[profile.uid];

    final rssiDelta = existing != null ? (rssiInt - existing.rssi).abs() : 999;
    final sinceLastEmitMs =
        lastEmit != null ? now.difference(lastEmit).inMilliseconds : 999999;

    if (sinceLastEmitMs < _minEmitIntervalMs && rssiDelta < 3) {
      // Aggiorniamo lastSeen per non marcarlo stale, ma non notifichiamo la UI.
      if (existing != null) {
        _nearbyMap[profile.uid] = NearbyUser(
          uid: existing.uid,
          displayName: existing.displayName,
          company: existing.company,
          role: existing.role,
          avatarURL: existing.avatarURL,
          bio: existing.bio,
          email: existing.email,
          linkedin: existing.linkedin,
          phone: existing.phone,
          rssi: rssiInt,
          lastSeen: raw.timestamp,
        );
      }
      _writeDetection(profile.uid, rssiInt);
      return;
    }

    _nearbyMap[profile.uid] = NearbyUser(
      uid: profile.uid,
      displayName: profile.displayName,
      company: profile.company,
      role: profile.role,
      avatarURL: profile.avatarURL,
      bio: profile.bio,
      email: '',
      linkedin: '',
      phone: '',
      rssi: rssiInt,
      lastSeen: raw.timestamp,
    );

    _lastEmitForUid[profile.uid] = now;
    _writeDetection(profile.uid, rssiInt);
    _emit();
  }

  Future<_CachedProfile?> _resolve(String sessionBleId) async {
    final cached = _resolveCache[sessionBleId];
    if (cached != null) return cached;

    final eventId = _eventId;
    if (eventId == null) return null;

    try {
      final doc = await _db
          .collection('events')
          .doc(eventId)
          .collection('proximityTokens')
          .doc(sessionBleId)
          .get();

      if (!doc.exists) return null;

      final data = doc.data();
      if (data == null) return null;

      // Non risolviamo token disattivati o scaduti: il peer non è più valido.
      if (!_isTokenUsable(data)) return null;

      final profile = _CachedProfile.fromData(data);
      _resolveCache[sessionBleId] = profile;
      return profile;
    } catch (e) {
      Log.e(_tag, 'Errore resolve $sessionBleId', e);
      return null;
    }
  }

  void _writeDetection(String detectedUid, int rssi) {
    final eventId = _eventId;
    final myUid = _myUid;
    if (eventId == null || myUid == null) return;

    final now = DateTime.now();
    final lastWrite = _lastDetectionWriteAt[detectedUid];

    if (lastWrite != null &&
        now.difference(lastWrite).inSeconds <
            AppConstants.detectionWriteDebounceSeconds) {
      return;
    }

    _lastDetectionWriteAt[detectedUid] = now;

    // Clamp di sicurezza: le Rules accettano solo rssi nell'intervallo
    // [-127, 0]. Lo smoothing/round non dovrebbe mai uscirne, ma ci
    // proteggiamo da valori anomali del plugin nativo.
    final safeRssi = rssi > 0 ? 0 : (rssi < -127 ? -127 : rssi);

    _db
        .collection('events')
        .doc(eventId)
        .collection('detections')
        .doc(myUid)
        .collection('nearby')
        .doc(detectedUid)
        .set({
      'rssi': safeRssi,
      'lastSeen': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true)).catchError((Object e) {
      Log.e(_tag, 'Errore write detection', e);
    });
  }

  void _removeStale() {
    final staleUids = _nearbyMap.entries
        .where((entry) => entry.value.isStale())
        .map((entry) => entry.key)
        .toList();

    if (staleUids.isEmpty) return;

    for (final uid in staleUids) {
      _nearbyMap.remove(uid);
      _lastDetectionWriteAt.remove(uid);
      _lastEmitForUid.remove(uid);

      // Fix leak: ripuliamo _rssiSmoothed usando il token associato all'uid.
      final token = _tokenByUid.remove(uid);
      if (token != null) {
        _rssiSmoothed.remove(token);
      }
    }

    _emit();
    Log.d(_tag, 'Rimossi ${staleUids.length} utenti stale');
  }

  void _emit() {
    if (_nearbyController.isClosed) return;
    _nearbyController.add(currentNearby);
  }

  bool isRecentlyDetected(
    String uid, {
    int maxSeconds = AppConstants.contactGatingSeconds,
  }) {
    final user = _nearbyMap[uid];
    if (user == null) return false;
    return !user.isStale(seconds: maxSeconds);
  }

  void clear() {
    _scanSub?.cancel();
    _scanSub = null;

    _mappingSub?.cancel();
    _mappingSub = null;

    _cleanupTimer?.cancel();
    _cleanupTimer = null;

    _nearbyMap.clear();
    _resolveCache.clear();
    _lastDetectionWriteAt.clear();
    _rssiSmoothed.clear();
    _lastEmitForUid.clear();
    _tokenByUid.clear();

    _eventId = null;
    _myUid = null;
    _mySessionBleId = null;

    _emit();
    Log.d(_tag, 'Servizio fermato e cache pulita');
  }

  void dispose() {
    clear();
    _nearbyController.close();
  }
}
