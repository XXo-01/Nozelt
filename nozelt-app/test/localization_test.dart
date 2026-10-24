import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/l10n/nozelt_l10n.dart';

void main() {
  test(
    'Russian and English localizations have identical keys/placeholders',
    () {
      final russian = NozeltL10n.debugTranslations('ru');
      final english = NozeltL10n.debugTranslations('en');

      expect(russian.keys.toSet(), english.keys.toSet());
      final placeholder = RegExp(r'\{[a-zA-Z0-9_]+\}');
      for (final key in english.keys) {
        expect(
          placeholder
              .allMatches(russian[key]!)
              .map((match) => match.group(0))
              .toSet(),
          placeholder
              .allMatches(english[key]!)
              .map((match) => match.group(0))
              .toSet(),
          reason: 'placeholder mismatch for localization key $key',
        );
      }
    },
  );
}
