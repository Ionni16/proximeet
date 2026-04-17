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
  final String email;
  final String linkedin;
  final String phone;

  _CachedProfile({
    required this.uid,
    required this.displayName,
    required this.company,
    required this.role,
    required this.avatarURL,
    this.bio = '',
    this.email = '',
    this.linkedin = '',
    this.phone = '',
  });
}

/// Orchestratore tra BLE scanner e UI.
///
/// 1. Ascolta [BleScannerService.detections]
/// 2. Risolve sessionBleId → uid + profilo completo
/// 3. Filtra duplicati e stale
/// 4. Scrive detections su Firestore (per gating)
/// 5. Emette [Stream<List<NearbyUser>>] per la UI
///
/// Singleton: usa [NearbyDetectionService.instance].
class NearbyDetectionService {
  NearbyDetectionService._();
  static final NearbyDetectionService instance = NearbyDetectionService._();

  final _db = FirebaseFirestore.instance;

  final Map<String, _CachedProfile> _resolveCache = {};
  final Map<String, NearbyUser> _nearbyMap = {};
  final _nearbyController = StreamController<List<NearbyUser>>.broadcast();

  Stream<List<NearbyUser>> get nearbyStream => _nearbyController.stream;

  List<NearbyUser> get currentNearby => _nearbyMap.values.toList()
    ..sort((a, b) => b.rssi.compareTo(a.rssi));

  StreamSubscription? _scanSub;
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
    if (_scanSub != null) return;

    _eventId = eventId;
    _myUid = myUid;
    _mySessionBleId = mySessionBleId;

    await _preloadCache(eventId);

    _scanSub = scanner.detections.listen(_onRawDetection);

    _cleanupTimer = Timer.periodic(
      const Duration(seconds: AppConstants.cleanupIntervalSeconds),
      (_) => _removeStale(),
    );

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
          uid: data['uid'] ?? '',
          displayName: data['displayName'] ?? '',
          company: data['company'] ?? '',
          role: data['role'] ?? '',
          avatarURL: data['avatarURL'] ?? '',
          bio: data['bio'] ?? '',
          email: data['email'] ?? '',
          linkedin: data['linkedin'] ?? '',
          phone: data['phone'] ?? '',
        );
      }
      Log.d('NEARBY', 'Cache precaricata: ${_resolveCache.length} utenti');
    } catch (e) {
      Log.e('NEARBY', 'Errore preload cache', e);
    }
  }

  Future<void> _onRawDetection(RawBleDetection raw) async {
    if (raw.sessionBleId == _mySessionBleId) return;

    final profile = await _resolve(raw.sessionBleId);
    if (profile == null) return;
    if (profile.uid == _myUid) return;

    _nearbyMap[profile.uid] = NearbyUser(
      uid: profile.uid,
      displayName: profile.displayName,
      company: profile.company,
      role: profile.role,
      avatarURL: profile.avatarURL,
      bio: profile.bio,
      email: profile.email,
      linkedin: profile.linkedin,
      phone: profile.phone,
      rssi: raw.rssi,
      lastSeen: raw.timestamp,
    );

    _writeDetection(profile.uid, raw.rssi);
    _emit();
  }

  Future<_CachedProfile?> _resolve(String sessionBleId) async {
    if (_resolveCache.containsKey(sessionBleId)) {
      return _resolveCache[sessionBleId];
    }

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
        bio: data['bio'] ?? '',
        email: data['email'] ?? '',
        linkedin: data['linkedin'] ?? '',
        phone: data['phone'] ?? '',
      );
      _resolveCache[sessionBleId] = profile;
      return profile;
    } catch (e) {
      Log.e('NEARBY', 'Errore resolve $sessionBleId', e);
      return null;
    }
  }

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

  void _removeStale() {
    final staleUids = _nearbyMap.entries
        .where((e) => e.value.isStale())
        .map((e) => e.key)
        .toList();

    if (staleUids.isEmpty) return;

    for (final uid in staleUids) {
      _nearbyMap.remove(uid);
    }
    _emit();
    Log.d('NEARBY', 'Rimossi ${staleUids.length} utenti stale');
  }

  void _emit() {
    if (!_nearbyController.isClosed) {
      _nearbyController.add(currentNearby);
    }
  }

  bool isRecentlyDetected(String uid, {int maxSeconds = AppConstants.contactGatingSeconds}) {
    final user = _nearbyMap[uid];
    if (user == null) return false;
    return !user.isStale(seconds: maxSeconds);
  }

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
    Log.d('NEARBY', 'Servizio fermato e cache pulita');
  }

  void dispose() {
    clear();
    _nearbyController.close();
  }
}
