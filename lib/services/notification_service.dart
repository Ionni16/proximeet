// lib/services/notification_service.dart
//
// Gestione centralizzata delle notifiche push (FCM).
//
// Cosa fa:
//   • foreground (onMessage)        → mostra una SnackBar con il testo
//   • tap su notifica (background)  → apre la schermata richieste
//   • app avviata da notifica       → apre la schermata richieste
//   • refresh del token FCM         → ri-salva il token su Firestore
//
// Il service non conosce le screen: riceve da main.dart una callback
// `onOpenRequests`, così la navigazione resta fuori dal layer service.
// ─────────────────────────────────────────────────────────────

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../core/logger.dart';
import 'auth_service.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const _tag = 'NOTIFICATIONS';

  /// Key dello ScaffoldMessenger globale (registrata in MaterialApp)
  /// usata per mostrare SnackBar anche senza un BuildContext.
  GlobalKey<ScaffoldMessengerState>? _messengerKey;

  /// Callback fornita da main.dart per aprire la schermata richieste.
  VoidCallback? _onOpenRequests;

  StreamSubscription<RemoteMessage>? _onMessageSub;
  StreamSubscription<RemoteMessage>? _onOpenedSub;
  StreamSubscription<String>? _onTokenRefreshSub;

  bool _initialized = false;

  /// Inizializza i listener FCM. Da chiamare una sola volta in main.dart,
  /// dopo Firebase.initializeApp().
  Future<void> init({
    required GlobalKey<ScaffoldMessengerState> messengerKey,
    required VoidCallback onOpenRequests,
  }) async {
    if (_initialized) return;
    _initialized = true;

    _messengerKey = messengerKey;
    _onOpenRequests = onOpenRequests;

    // 1) Notifica ricevuta con app in foreground → SnackBar.
    _onMessageSub = FirebaseMessaging.onMessage.listen(
      _handleForegroundMessage,
      onError: (Object e) => Log.e(_tag, 'Errore stream onMessage', e),
    );

    // 2) Tap su notifica con app in background → naviga alle richieste.
    _onOpenedSub = FirebaseMessaging.onMessageOpenedApp.listen(
      (_) => _openRequestsIfLoggedIn(),
      onError: (Object e) => Log.e(_tag, 'Errore stream onMessageOpenedApp', e),
    );

    // 3) App avviata (da terminata) tramite tap su notifica.
    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        // Piccolo delay: lasciamo che il primo frame e l'auth gate
        // siano montati prima di pushare la schermata richieste.
        Future.delayed(
          const Duration(milliseconds: 600),
          _openRequestsIfLoggedIn,
        );
      }
    } catch (e) {
      Log.e(_tag, 'Errore getInitialMessage', e);
    }

    // 4) Il token FCM può ruotare: lo ri-salviamo su Firestore.
    _onTokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen(
      (token) {
        AuthService.instance.persistFcmToken(token).catchError((Object e) {
          Log.e(_tag, 'Errore salvataggio token FCM aggiornato', e);
        });
      },
      onError: (Object e) => Log.e(_tag, 'Errore stream onTokenRefresh', e),
    );

    Log.d(_tag, 'NotificationService inizializzato');
  }

  void _handleForegroundMessage(RemoteMessage message) {
    final notification = message.notification;
    if (notification == null) return;

    final title = notification.title?.trim() ?? '';
    final body = notification.body?.trim() ?? '';
    final text = [title, body].where((s) => s.isNotEmpty).join(' — ');
    if (text.isEmpty) return;

    Log.d(_tag, 'Notifica in foreground: $text');

    _messengerKey?.currentState?.showSnackBar(
      SnackBar(
        content: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Apri',
          onPressed: _openRequestsIfLoggedIn,
        ),
      ),
    );
  }

  void _openRequestsIfLoggedIn() {
    // Guard: se nel frattempo l'utente ha fatto logout, non navighiamo.
    if (FirebaseAuth.instance.currentUser == null) {
      Log.w(_tag, 'Tap su notifica ma utente non autenticato: ignoro');
      return;
    }
    _onOpenRequests?.call();
  }

  /// Rilascia i listener (utile nei test; in app vive per tutta la sessione).
  Future<void> dispose() async {
    await _onMessageSub?.cancel();
    await _onOpenedSub?.cancel();
    await _onTokenRefreshSub?.cancel();
    _onMessageSub = null;
    _onOpenedSub = null;
    _onTokenRefreshSub = null;
    _initialized = false;
  }
}
