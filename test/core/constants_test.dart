import 'package:flutter_test/flutter_test.dart';
import 'package:ProxiMeet/core/constants.dart';

void main() {
  group('AppConstants.beaconKey / parseBeaconKey', () {
    test('beaconKey formatta con padding a 5 cifre', () {
      expect(AppConstants.beaconKey(1, 2), '00001_00002');
      expect(AppConstants.beaconKey(65535, 0), '65535_00000');
    });

    test('parseBeaconKey round-trip', () {
      final key = AppConstants.beaconKey(123, 456);
      final parsed = AppConstants.parseBeaconKey(key);
      expect(parsed.major, 123);
      expect(parsed.minor, 456);
    });

    test('parseBeaconKey rifiuta formati non validi', () {
      expect(() => AppConstants.parseBeaconKey('abc'), throwsFormatException);
      expect(() => AppConstants.parseBeaconKey('1_2_3'), throwsFormatException);
      expect(() => AppConstants.parseBeaconKey('99999_99999'),
          throwsFormatException); // fuori range 0..65535
    });

    test('isValidBeaconKey distingue valide e non valide', () {
      expect(AppConstants.isValidBeaconKey('00001_00002'), isTrue);
      expect(AppConstants.isValidBeaconKey('not-a-key'), isFalse);
      expect(AppConstants.isValidBeaconKey('70000_1'), isFalse);
    });
  });

  group('AppConstants.isValidProximityToken', () {
    test('accetta token nel formato atteso', () {
      expect(
        AppConstants.isValidProximityToken('pm:abc123:0123456789abcdef'),
        isTrue,
      );
      expect(
        AppConstants.isValidProximityToken('A1b2C3d4E5f6G7h8'),
        isTrue,
      );
    });

    test('rifiuta token troppo corti o troppo lunghi', () {
      expect(AppConstants.isValidProximityToken('short'), isFalse);
      expect(
        AppConstants.isValidProximityToken('x' * 129),
        isFalse,
      );
    });

    test('rifiuta token con spazi o caratteri non ammessi', () {
      expect(AppConstants.isValidProximityToken('ha spazio interno!!'), isFalse);
      expect(
        AppConstants.isValidProximityToken(' leadingspace1234567'),
        isFalse,
      );
      expect(
        AppConstants.isValidProximityToken('contains/slash/1234567'),
        isFalse,
      );
    });
  });
}
