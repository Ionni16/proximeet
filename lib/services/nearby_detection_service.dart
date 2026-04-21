import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../models/nearby_user.dart';
import 'ble_scanner_service.dart';

/// Profilo cachato dal bleMapping.
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
}

/// Orchestratore tra BLE scanner e UI.
///
/// 1. Ascolta [BleScannerService.detections]
/// 2. Risolve sessionBleId → uid + profilo pubblico
/// 3. Filtra duplicati e stale
/// 4. Scrive detections su Firestore (per gating)
/// 5. Emette [Stream<List<NearbyUser>>] per la UI
///
/// Singleton: usa [NearbyDetectionService.instance].
class NearbyDetectionService {
  NearbyDetectionService._();
  static final NearbyDetectionService instance = NearbyDetectionService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  final Map<String, _CachedProfile> _resolveCache = {};
  final Map<String, NearbyUser> _nearbyMap = {};
  final Map<String, DateTime> _lastDetectionWriteAt = {};
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

  Future<void> start({
    required String eventId,
    required String myUid,
    required String mySessionBleId,
    required BleScannerService scanner,
  }) async {
    if (_scanSub != null) {
      // Se sta già girando sullo stesso evento, non fare nulla.
      if (_eventId == eventId &&
          _myUid == myUid &&
          _mySessionBleId == mySessionBleId) {
        return;
      }

      // Se per qualche motivo era partito su uno stato diverso, pulisci.
      clear();
    }

    _eventId = eventId;
    _myUid = myUid;
    _mySessionBleId = mySessionBleId;

    await _preloadCache(eventId);

    _scanSub = scanner.detections.listen(
      _onRawDetection,
      onError: (e) => Log.e('NEARBY', 'Errore stream detections', e),
    );

    // Listener live sul bleMapping:
    // se un utente cambia foto/nome/ruolo, aggiorniamo la cache
    // e anche i nearby già presenti in lista.
    _mappingSub = _db
        .collection('events')
        .doc(eventId)
        .collection('bleMapping')
        .snapshots()
        .listen(
      _onMappingChange,
      onError: (e) => Log.e('NEARBY', 'Errore stream bleMapping', e),
    );

    _cleanupTimer = Timer.periodic(
      const Duration(seconds: AppConstants.cleanupIntervalSeconds),
      (_) => _removeStale(),
    );

    _emit();
    Log.d('NEARBY', 'Avviato per evento $eventId');
  }

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
          uid: (data['uid'] ?? '') as String,
          displayName: (data['displayName'] ?? '') as String,
          company: (data['company'] ?? '') as String,
          role: (data['role'] ?? '') as String,
          avatarURL: (data['avatarURL'] ?? '') as String,
          bio: (data['bio'] ?? '') as String,
        );
      }

      Log.d('NEARBY', 'Cache precaricata: ${_resolveCache.length} utenti');
    } catch (e) {
      Log.e('NEARBY', 'Errore preload cache', e);
    }
  }

  /// Aggiorna cache + nearbyMap quando cambia il bleMapping.
  void _onMappingChange(QuerySnapshot<Map<String, dynamic>> snap) {
    bool anyChange = false;

    for (final doc in snap.docs) {
      final data = doc.data();

      final newProfile = _CachedProfile(
        uid: (data['uid'] ?? '') as String,
        displayName: (data['displayName'] ?? '') as String,
        company: (data['company'] ?? '') as String,
        role: (data['role'] ?? '') as String,
        avatarURL: (data['avatarURL'] ?? '') as String,
        bio: (data['bio'] ?? '') as String,
      );

      _resolveCache[doc.id] = newProfile;

      // Se questo utente è già nei nearby, aggiorna il profilo
      // ma mantieni gli attributi runtime (rssi, lastSeen).
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

    if (anyChange) {
      _emit();
    }
  }

  Future<void> _onRawDetection(RawBleDetection raw) async {
    if (raw.sessionBleId == _mySessionBleId) return;

    final profile = await _resolve(raw.sessionBleId);
    if (profile == null) return;
    if (profile.uid.isEmpty) return;
    if (profile.uid == _myUid) return;

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
      rssi: raw.rssi,
      lastSeen: raw.timestamp,
    );

    _writeDetection(profile.uid, raw.rssi);
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
          .collection('bleMapping')
          .doc(sessionBleId)
          .get();

      if (!doc.exists) return null;

      final data = doc.data();
      if (data == null) return null;

      final profile = _CachedProfile(
        uid: (data['uid'] ?? '') as String,
        displayName: (data['displayName'] ?? '') as String,
        company: (data['company'] ?? '') as String,
        role: (data['role'] ?? '') as String,
        avatarURL: (data['avatarURL'] ?? '') as String,
        bio: (data['bio'] ?? '') as String,
      );

      _resolveCache[sessionBleId] = profile;
      return profile;
    } catch (e) {
      Log.e('NEARBY', 'Errore resolve $sessionBleId', e);
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

    _db
        .collection('events')
        .doc(eventId)
        .collection('detections')
        .doc(myUid)
        .collection('nearby')
        .doc(detectedUid)
        .set({
      'rssi': rssi,
      'lastSeen': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true)).catchError((e) {
      Log.e('NEARBY', 'Errore write detection', e);
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
    }

    _emit();
    Log.d('NEARBY', 'Rimossi ${staleUids.length} utenti stale');
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

    _eventId = null;
    _myUid = null;
    _mySessionBleId = null;

    _emit();
    Log.d('NEARBY', 'Servizio fermato e cache pulita');
  }

  void dispose() {
    clear();
    _nearbyController.close();
  }
}