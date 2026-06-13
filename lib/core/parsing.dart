// lib/core/parsing.dart
//
// Utility di parsing difensivo condivise dai modelli.
//
// Motivazione: i documenti Firestore possono contenere date in formati
// diversi (Timestamp nativo, stringa ISO8601, int millisecondi, o un
// DateTime già deserializzato). Un cast duro `as Timestamp` fa crashare
// l'intera lista se anche un solo documento è malformato. Queste helper
// degradano in modo morbido restituendo null invece di lanciare.
// ─────────────────────────────────────────────────────────────

import 'package:cloud_firestore/cloud_firestore.dart';

/// Converte un valore eterogeneo in [DateTime], oppure null se non
/// interpretabile. Accetta Timestamp, DateTime, stringa ISO8601 e
/// int/double in millisecondi dall'epoch.
DateTime? parseDateTime(dynamic value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }
  if (value is double) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return DateTime.tryParse(trimmed);
  }
  return null;
}

/// Come [parseDateTime] ma con un fallback garantito (default: epoch),
/// per i campi che il resto del codice si aspetta non-null.
DateTime parseDateTimeOr(dynamic value, {DateTime? fallback}) {
  return parseDateTime(value) ??
      fallback ??
      DateTime.fromMillisecondsSinceEpoch(0);
}

/// Interpreta un valore come bool in modo permissivo.
/// `true` solo per: bool true, "true"/"1"/"yes" (case-insensitive), 1.
bool parseBool(dynamic value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value == 1;
  if (value is String) {
    final v = value.trim().toLowerCase();
    if (v == 'true' || v == '1' || v == 'yes') return true;
    if (v == 'false' || v == '0' || v == 'no') return false;
  }
  return fallback;
}

/// Converte un valore in stringa "pulita" (trim), null-safe.
String parseString(dynamic value) => (value ?? '').toString().trim();
