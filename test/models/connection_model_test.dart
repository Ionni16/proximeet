import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ProxiMeet/models/connection_model.dart';

void main() {
  group('ConnectionRequest.fromMap', () {
    test('legge i campi con trim', () {
      final req = ConnectionRequest.fromMap('r1', {
        'senderUid': ' s1 ',
        'receiverUid': ' r1 ',
        'eventId': ' e1 ',
        'status': 'pending',
        'senderDisplayName': ' Mario Rossi ',
        'senderRole': ' Dev ',
        'senderCompany': ' ACME ',
        'senderAvatarURL': ' https://x/y.jpg ',
        'createdAt': Timestamp.fromDate(DateTime(2026, 1, 1)),
      });

      expect(req.id, 'r1');
      expect(req.senderUid, 's1');
      expect(req.receiverUid, 'r1');
      expect(req.senderDisplayName, 'Mario Rossi');
      expect(req.senderAvatarURL, 'https://x/y.jpg');
      expect(req.createdAt, isNotNull);
    });

    test('status assente → pending', () {
      final req = ConnectionRequest.fromMap('r2', {
        'senderUid': 's',
        'receiverUid': 'r',
        'eventId': 'e',
      });
      expect(req.status, 'pending');
    });

    test('createdAt malformato → null senza lanciare', () {
      final req = ConnectionRequest.fromMap('r3', {
        'senderUid': 's',
        'receiverUid': 'r',
        'eventId': 'e',
        'createdAt': 'non-valido',
      });
      expect(req.createdAt, isNull);
    });
  });

  group('WalletContact.fromMap', () {
    test('legge avatar dalla chiave canonica avatarURL', () {
      final c = WalletContact.fromMap({
        'uid': 'u1',
        'firstName': 'Ada',
        'lastName': 'Lovelace',
        'avatarURL': 'https://x/ada.jpg',
      });
      expect(c.avatarURL, 'https://x/ada.jpg');
    });

    test('retro-compatibilità: legge avatar da chiavi legacy', () {
      expect(
        WalletContact.fromMap({'uid': 'u', 'photoURL': 'p.jpg'}).avatarURL,
        'p.jpg',
      );
      expect(
        WalletContact.fromMap({'uid': 'u', 'avatarUrl': 'a.jpg'}).avatarURL,
        'a.jpg',
      );
      expect(
        WalletContact.fromMap({'uid': 'u', 'avatar': 'leg.jpg'}).avatarURL,
        'leg.jpg',
      );
    });

    test('avatarURL canonica ha priorità sulle legacy', () {
      final c = WalletContact.fromMap({
        'uid': 'u',
        'avatarURL': 'canonical.jpg',
        'photoURL': 'legacy.jpg',
      });
      expect(c.avatarURL, 'canonical.jpg');
    });
  });

  group('WalletContact.fullName', () {
    test('compone nome e cognome', () {
      final c = WalletContact.fromMap({
        'uid': 'u',
        'firstName': 'Ada',
        'lastName': 'Lovelace',
      });
      expect(c.fullName, 'Ada Lovelace');
    });

    test('fallback "Contatto" se nome e cognome vuoti', () {
      final c = WalletContact.fromMap({'uid': 'u'});
      expect(c.fullName, 'Contatto');
    });
  });

  group('WalletContact.toMap', () {
    test('serializza una sola chiave avatar (avatarURL) senza legacy', () {
      final c = WalletContact.fromMap({
        'uid': 'u',
        'firstName': 'A',
        'lastName': 'B',
        'avatarURL': 'x.jpg',
      });
      final map = c.toMap();
      expect(map['avatarURL'], 'x.jpg');
      expect(map.containsKey('avatarUrl'), isFalse);
      expect(map.containsKey('photoURL'), isFalse);
      expect(map.containsKey('avatar'), isFalse);
    });
  });
}
