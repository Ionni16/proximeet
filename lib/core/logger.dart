import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';

/// Logger semplice per stampare messaggi di debug, warning ed errori.
/// Usa debugPrint così i log si vedono sempre nel terminale,
/// e dev.log per averli anche in DevTools.
abstract final class Log {
  /// Messaggio di debug: per seguire cosa fa il codice passo per passo.
  static void d(String tag, String message) {
    debugPrint('[$tag] 🟦 $message');
    dev.log(message, name: tag, level: 500);
  }

  /// Warning: qualcosa di strano, ma l'app non si è bloccata.
  static void w(String tag, String message) {
    debugPrint('[$tag] ⚠️ $message');
    dev.log('⚠️ $message', name: tag, level: 900);
  }

  /// Errore: eccezione catturata, con messaggio e stack trace opzionali.
  static void e(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    debugPrint('[$tag] ❌ $message');
    if (error != null) debugPrint('[$tag] Dettagli: $error');
    
    dev.log(
      '❌ $message',
      name: tag,
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
  }
}