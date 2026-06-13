import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ProxiMeet/models/user_model.dart';

void main() {
  group('UserModel.fromMap', () {
    test('legge i campi base con trim e lowercase email', () {
      final user = UserModel.fromMap({
        'uid': '  abc123  ',
        'firstName': ' Mario ',
        'lastName': ' Rossi ',
        'email': '  Mario.Rossi@EXAMPLE.com ',
        'company': ' ACME ',
        'role': ' Dev ',
        'avatarURL': ' https://x/y.jpg ',
        'createdAt': Timestamp.fromDate(DateTime(2026, 1, 1)),
      });

      expect(user.uid, 'abc123');
      expect(user.firstName, 'Mario');
      expect(user.lastName, 'Rossi');
      expect(user.email, 'mario.rossi@example.com');
      expect(user.company, 'ACME');
      expect(user.avatarURL, 'https://x/y.jpg');
    });

    test('campi opzionali vuoti diventano null', () {
      final user = UserModel.fromMap({
        'uid': 'u1',
        'firstName': 'A',
        'lastName': 'B',
        'email': 'a@b.c',
        'company': 'C',
        'role': 'R',
        'avatarURL': '',
        'linkedin': '',
        'phone': '   ',
      });

      expect(user.linkedin, isNull);
      expect(user.phone, isNull);
    });

    test('createdAt da stringa ISO non lancia', () {
      final user = UserModel.fromMap({
        'uid': 'u1',
        'firstName': 'A',
        'lastName': 'B',
        'email': 'a@b.c',
        'company': 'C',
        'role': 'R',
        'avatarURL': '',
        'createdAt': '2026-05-01T12:00:00.000Z',
      });
      expect(user.createdAt.toUtc().year, 2026);
    });
  });

  group('UserModel.fullName', () {
    test('compone nome e cognome', () {
      final user = _user(firstName: 'Mario', lastName: 'Rossi');
      expect(user.fullName, 'Mario Rossi');
    });

    test('gestisce cognome mancante senza spazi pendenti', () {
      final user = _user(firstName: 'Mario', lastName: '');
      expect(user.fullName, 'Mario');
    });
  });

  group('UserModel.toSummary', () {
    test('contiene displayName e campi compatti', () {
      final user = _user(firstName: 'Ada', lastName: 'Lovelace');
      final summary = user.toSummary();
      expect(summary['uid'], user.uid);
      expect(summary['displayName'], 'Ada Lovelace');
      expect(summary.containsKey('company'), isTrue);
      expect(summary.containsKey('role'), isTrue);
      expect(summary.containsKey('avatarURL'), isTrue);
    });
  });

  group('UserModel round-trip toMap → fromMap', () {
    test('preserva i campi', () {
      final original = UserModel(
        uid: 'u9',
        firstName: 'Grace',
        lastName: 'Hopper',
        email: 'grace@navy.mil',
        company: 'US Navy',
        role: 'Rear Admiral',
        avatarURL: 'https://x/avatar.jpg',
        linkedin: 'https://linkedin.com/in/grace',
        createdAt: DateTime(2026, 6, 1),
      );

      final restored = UserModel.fromMap(original.toMap());

      expect(restored.uid, original.uid);
      expect(restored.firstName, original.firstName);
      expect(restored.lastName, original.lastName);
      expect(restored.email, original.email);
      expect(restored.company, original.company);
      expect(restored.role, original.role);
      expect(restored.avatarURL, original.avatarURL);
      expect(restored.linkedin, original.linkedin);
    });
  });
}

UserModel _user({required String firstName, required String lastName}) {
  return UserModel(
    uid: 'uid-test',
    firstName: firstName,
    lastName: lastName,
    email: 'test@example.com',
    company: 'Co',
    role: 'Role',
    avatarURL: '',
    createdAt: DateTime(2026, 1, 1),
  );
}
