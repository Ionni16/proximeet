import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ProxiMeet/models/event_model.dart';

void main() {
  group('EventModel.fromMap', () {
    test('legge i campi da Timestamp', () {
      final event = EventModel.fromMap('e1', {
        'name': 'DevFest',
        'description': 'Conferenza',
        'location': 'Milano',
        'startDate': Timestamp.fromDate(DateTime(2026, 9, 1, 9)),
        'endDate': Timestamp.fromDate(DateTime(2026, 9, 1, 18)),
        'isActive': true,
      });

      expect(event.id, 'e1');
      expect(event.name, 'DevFest');
      expect(event.location, 'Milano');
      expect(event.isActive, isTrue);
      expect(event.startDate, DateTime(2026, 9, 1, 9));
    });

    test('NON lancia su date malformate (degrada a epoch)', () {
      final event = EventModel.fromMap('e2', {
        'name': 'Evento rotto',
        'startDate': 'data-non-valida',
        'endDate': null,
        'isActive': 'true',
      });

      // Il punto chiave: niente eccezione, l'oggetto è costruito.
      expect(event.name, 'Evento rotto');
      expect(event.startDate, DateTime.fromMillisecondsSinceEpoch(0));
      expect(event.endDate, DateTime.fromMillisecondsSinceEpoch(0));
      expect(event.isActive, isTrue); // 'true' stringa interpretata come bool
    });

    test('isActive assente → false', () {
      final event = EventModel.fromMap('e3', {'name': 'X'});
      expect(event.isActive, isFalse);
    });

    test('startDate da stringa ISO viene interpretata', () {
      final event = EventModel.fromMap('e4', {
        'name': 'ISO',
        'startDate': '2026-07-15T10:00:00.000Z',
        'endDate': '2026-07-15T12:00:00.000Z',
        'isActive': true,
      });
      expect(event.startDate.toUtc().month, 7);
      expect(event.endDate.toUtc().hour, 12);
    });
  });

  group('EventModel.isOngoing', () {
    test('true se ora è tra start e end', () {
      final now = DateTime.now();
      final event = EventModel(
        id: 'e',
        name: 'Now',
        location: 'Qui',
        startDate: now.subtract(const Duration(hours: 1)),
        endDate: now.add(const Duration(hours: 1)),
        isActive: true,
      );
      expect(event.isOngoing, isTrue);
    });

    test('false se già finito', () {
      final now = DateTime.now();
      final event = EventModel(
        id: 'e',
        name: 'Past',
        location: 'Qui',
        startDate: now.subtract(const Duration(hours: 3)),
        endDate: now.subtract(const Duration(hours: 1)),
        isActive: false,
      );
      expect(event.isOngoing, isFalse);
    });
  });

  group('EventModel.dateRange', () {
    test('formatta giorno/mese', () {
      final event = EventModel(
        id: 'e',
        name: 'R',
        location: 'L',
        startDate: DateTime(2026, 9, 1),
        endDate: DateTime(2026, 9, 3),
        isActive: true,
      );
      expect(event.dateRange, '1/9 – 3/9');
    });
  });
}
