import 'dart:developer' as dev;

/// Logger centralizzato.
///
/// Usa `dart:developer` log() che:
/// - appare nel DevTools
/// - può essere filtrato per tag
/// - in release mode non ha overhead
///
/// Uso: `Log.d('SESSION', 'Join completato');`
abstract final class Log {
  /// Debug – informazioni di flusso.
  static void d(String tag, String message) {
    dev.log(message, name: tag, level: 500);
  }

  /// Warning – qualcosa di inaspettato ma gestito.
  static void w(String tag, String message) {
    dev.log('⚠️ $message', name: tag, level: 900);
  }

  /// Error – errore catturato.
  static void e(String tag, String message, [Object? error]) {
    dev.log('❌ $message', name: tag, level: 1000, error: error);
  }
}
