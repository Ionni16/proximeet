import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';

/// Logger centralizzato.
///
/// Usa `debugPrint` per forzare la visibilità nel terminale standard
/// e `dev.log` per mantenere la compatibilità col DevTools.
abstract final class Log {
  /// Debug – informazioni di flusso.
  static void d(String tag, String message) {
    debugPrint('[$tag] 🟦 $message');
    dev.log(message, name: tag, level: 500);
  }

  /// Warning – qualcosa di inaspettato ma gestito.
  static void w(String tag, String message) {
    debugPrint('[$tag] ⚠️ $message');
    dev.log('⚠️ $message', name: tag, level: 900);
  }

  /// Error – errore catturato.
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