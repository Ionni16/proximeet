import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';

import '../core/app_debug_error.dart';
import '../core/logger.dart';

class DebugErrorService {
  DebugErrorService._();

  static final DebugErrorService instance = DebugErrorService._();

  final List<AppDebugError> _items = <AppDebugError>[];
  final StreamController<List<AppDebugError>> _controller =
      StreamController<List<AppDebugError>>.broadcast();

  List<AppDebugError> get items => List.unmodifiable(_items);
  AppDebugError? get latest => _items.isEmpty ? null : _items.last;
  Stream<List<AppDebugError>> get stream => _controller.stream;

  AppDebugError add(AppDebugError error) {
    _items.add(error);
    if (_items.length > 50) _items.removeAt(0);
    _controller.add(items);
    Log.e(error.area, '${error.code}: ${error.message}', error.error, error.stackTrace);
    return error;
  }

  void clear() {
    _items.clear();
    _controller.add(items);
  }

  AppDebugError fromException({
    required String area,
    required String fallbackTitle,
    required String fallbackMessage,
    required String fallbackSuggestion,
    required Object error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    if (error is FirebaseException) {
      return add(AppDebugError(
        title: _firebaseTitle(error),
        area: area,
        code: 'FIREBASE_${error.code.toUpperCase().replaceAll('-', '_')}',
        message: error.message ?? fallbackMessage,
        suggestion: _firebaseSuggestion(error),
        data: <String, Object?>{
          ...data,
          'plugin': error.plugin,
          'firebaseCode': error.code,
        },
        error: error,
        stackTrace: stackTrace,
      ));
    }

    if (error is PlatformException) {
      return add(AppDebugError(
        title: _platformTitle(error),
        area: area,
        code: 'PLATFORM_${error.code.toUpperCase().replaceAll('-', '_')}',
        message: error.message ?? fallbackMessage,
        suggestion: _platformSuggestion(error),
        data: <String, Object?>{
          ...data,
          'platformCode': error.code,
          'details': error.details,
        },
        error: error,
        stackTrace: stackTrace,
      ));
    }

    return add(AppDebugError(
      title: fallbackTitle,
      area: area,
      code: 'APP_UNKNOWN',
      message: error.toString().isEmpty ? fallbackMessage : error.toString(),
      suggestion: fallbackSuggestion,
      data: data,
      error: error,
      stackTrace: stackTrace,
    ));
  }

  String _firebaseTitle(FirebaseException e) {
    switch (e.code) {
      case 'permission-denied':
        return 'Permessi Firestore insufficienti';
      case 'unavailable':
        return 'Firebase non disponibile';
      case 'not-found':
        return 'Documento Firebase non trovato';
      case 'unauthenticated':
        return 'Utente non autenticato';
      default:
        return 'Errore Firebase';
    }
  }

  String _firebaseSuggestion(FirebaseException e) {
    switch (e.code) {
      case 'permission-denied':
        return 'Controlla le Firestore Rules per events/{eventId}/presence e events/{eventId}/bleMapping. Verifica anche che l’utente sia autenticato.';
      case 'unavailable':
        return 'Controlla connessione internet e stato Firebase. Riprova dopo qualche secondo.';
      case 'not-found':
        return 'Controlla che eventId sia corretto e che il documento evento esista.';
      case 'unauthenticated':
        return 'Rifai login prima di entrare nell’evento.';
      default:
        return 'Apri i dettagli, copia il debug e controlla codice/plugin Firebase.';
    }
  }

  String _platformTitle(PlatformException e) {
    switch (e.code) {
      case 'BAD_ARGS':
        return 'Parametri beacon mancanti';
      case 'BAD_UUID':
        return 'UUID iBeacon non valido';
      case 'BAD_MAJOR_MINOR':
        return 'Major/minor iBeacon non validi';
      case 'NO_PERMISSION':
        return 'Permessi nativi mancanti';
      case 'BT_OFF':
        return 'Bluetooth spento o non disponibile';
      case 'ADV_UNSUPPORTED':
        return 'BLE advertising non supportato';
      default:
        return 'Errore nativo piattaforma';
    }
  }

  String _platformSuggestion(PlatformException e) {
    switch (e.code) {
      case 'BAD_ARGS':
        return 'Controlla PlatformBeaconService.start(): deve passare uuid, major e minor.';
      case 'BAD_UUID':
        return 'Controlla AppConstants.proximeetBeaconUuid.';
      case 'BAD_MAJOR_MINOR':
        return 'Controlla AppConstants.beaconKey() e parseBeaconKey(). Devono produrre valori 0...65535.';
      case 'NO_PERMISSION':
        return 'Su iOS controlla Bluetooth/Localizzazione in Impostazioni. Su Android controlla BLUETOOTH_SCAN/ADVERTISE/CONNECT e Location.';
      case 'BT_OFF':
        return 'Attiva Bluetooth e riapri l’app.';
      case 'ADV_UNSUPPORTED':
        return 'Questo device Android non supporta BLE advertising. Il join deve comunque continuare.';
      default:
        return 'Copia i dettagli e controlla AppDelegate.swift / ProxiMeetBeaconPlugin.kt.';
    }
  }
}
