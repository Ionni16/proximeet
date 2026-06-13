import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ProxiMeet/core/parsing.dart';

void main() {
  group('parseDateTime', () {
    test('gestisce Timestamp', () {
      final ts = Timestamp.fromDate(DateTime(2026, 1, 15, 10, 30));
      expect(parseDateTime(ts), DateTime(2026, 1, 15, 10, 30));
    });

    test('gestisce DateTime', () {
      final dt = DateTime(2026, 2, 1);
      expect(parseDateTime(dt), dt);
    });

    test('gestisce stringa ISO8601', () {
      final parsed = parseDateTime('2026-03-10T08:00:00.000Z');
      expect(parsed, isNotNull);
      expect(parsed!.toUtc().year, 2026);
      expect(parsed.toUtc().month, 3);
    });

    test('gestisce int millisecondi', () {
      final millis = DateTime(2026, 4, 1).millisecondsSinceEpoch;
      expect(parseDateTime(millis), DateTime(2026, 4, 1));
    });

    test('ritorna null su valori non interpretabili', () {
      expect(parseDateTime(null), isNull);
      expect(parseDateTime('non-una-data'), isNull);
      expect(parseDateTime(''), isNull);
      expect(parseDateTime(<String, dynamic>{}), isNull);
    });
  });

  group('parseDateTimeOr', () {
    test('usa il fallback quando non interpretabile', () {
      final fallback = DateTime(2000, 1, 1);
      expect(parseDateTimeOr(null, fallback: fallback), fallback);
      expect(parseDateTimeOr('garbage', fallback: fallback), fallback);
    });

    test('default epoch senza fallback', () {
      expect(
        parseDateTimeOr(null),
        DateTime.fromMillisecondsSinceEpoch(0),
      );
    });
  });

  group('parseBool', () {
    test('bool diretto', () {
      expect(parseBool(true), isTrue);
      expect(parseBool(false), isFalse);
    });

    test('stringhe', () {
      expect(parseBool('true'), isTrue);
      expect(parseBool('TRUE'), isTrue);
      expect(parseBool('1'), isTrue);
      expect(parseBool('yes'), isTrue);
      expect(parseBool('false'), isFalse);
      expect(parseBool('no'), isFalse);
    });

    test('numeri', () {
      expect(parseBool(1), isTrue);
      expect(parseBool(0), isFalse);
    });

    test('fallback su valori ignoti', () {
      expect(parseBool(null), isFalse);
      expect(parseBool('maybe'), isFalse);
      expect(parseBool(null, fallback: true), isTrue);
    });
  });

  group('parseString', () {
    test('trim e null-safety', () {
      expect(parseString('  ciao  '), 'ciao');
      expect(parseString(null), '');
      expect(parseString(42), '42');
    });
  });
}
