import 'package:flutter/foundation.dart';

@immutable
class AppDebugError {
  AppDebugError({
    required this.title,
    required this.area,
    required this.code,
    required this.message,
    required this.suggestion,
    this.data = const <String, Object?>{},
    this.error,
    this.stackTrace,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String title;
  final String area;
  final String code;
  final String message;
  final String suggestion;
  final Map<String, Object?> data;
  final Object? error;
  final StackTrace? stackTrace;
  final DateTime createdAt;

  String get shortText => '$title ($code)';

  String toCopyText() {
    final buffer = StringBuffer()
      ..writeln('=== ProxiMeet Debug Error ===')
      ..writeln('Data: ${createdAt.toIso8601String()}')
      ..writeln('Area: $area')
      ..writeln('Codice: $code')
      ..writeln('Titolo: $title')
      ..writeln('Messaggio: $message')
      ..writeln('Suggerimento: $suggestion');

    if (data.isNotEmpty) {
      buffer.writeln('\n--- Dati ---');
      for (final entry in data.entries) {
        buffer.writeln('${entry.key}: ${entry.value}');
      }
    }

    if (error != null) {
      buffer.writeln('\n--- Errore originale ---');
      buffer.writeln(error);
    }

    if (stackTrace != null) {
      buffer.writeln('\n--- StackTrace ---');
      buffer.writeln(stackTrace);
    }

    return buffer.toString();
  }

  @override
  String toString() => toCopyText();
}
