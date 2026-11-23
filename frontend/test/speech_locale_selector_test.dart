import 'package:flutter_test/flutter_test.dart';
import 'package:tinigsenyas/services/speech_locale_selector.dart';

void main() {
  group('selectOfflineFilipinoLocale', () {
    test('prefers Filipino Philippines and normalizes underscore IDs', () {
      expect(
        selectOfflineFilipinoLocale(['en-US', 'tl_PH', 'fil-PH']),
        'fil-PH',
      );
    });

    test('accepts a Tagalog locale alias when Filipino is unavailable', () {
      expect(selectOfflineFilipinoLocale(['en-US', 'tl-PH']), 'tl-PH');
    });

    test('returns null when no offline Filipino locale is available', () {
      expect(selectOfflineFilipinoLocale(['en-US', 'es-ES']), isNull);
    });

    test('does not treat unrelated locale prefixes as Filipino', () {
      expect(selectOfflineFilipinoLocale(['filipino-XX']), isNull);
    });
  });
}
