import 'package:campus_atlas/core/i18n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('translation tables', () {
    test('zh and en define exactly the same keys', () {
      final zh = AppLocalizations.zhKeys;
      final en = AppLocalizations.enKeys;

      final missingInEn = zh.difference(en);
      final missingInZh = en.difference(zh);

      expect(
        missingInEn,
        isEmpty,
        reason: 'keys present in zh but missing in en: $missingInEn',
      );
      expect(
        missingInZh,
        isEmpty,
        reason: 'keys present in en but missing in zh: $missingInZh',
      );
    });

    test('no value is blank', () {
      for (final key in AppLocalizations.zhKeys) {
        final zh = AppLocalizations(const Locale('zh'));
        final en = AppLocalizations(const Locale('en'));
        expect(zh.debugValueFor(key), isNotEmpty, reason: 'zh $key');
        expect(en.debugValueFor(key), isNotEmpty, reason: 'en $key');
      }
    });
  });

  group('lookup', () {
    test('zh resolves the app title', () {
      expect(
        AppLocalizations(const Locale('zh')).appTitle,
        isNotEmpty,
      );
    });

    test('en resolves the same key independently', () {
      final en = AppLocalizations(const Locale('en'));
      expect(en.appTitle, isNotEmpty);
      expect(en.settingsTitle, 'Settings');
      expect(en.navTimetable, 'Timetable');
    });

    test('an unsupported language code falls back to zh', () {
      final fr = AppLocalizations(const Locale('fr'));
      expect(fr.appTitle, isNotEmpty);
      expect(
          fr.settingsTitle, AppLocalizations(const Locale('zh')).settingsTitle);
    });

    test('errorFor maps every FailureKind name to a non-empty message', () {
      const names = [
        'network',
        'timeout',
        'unauthorized',
        'challengeRequired',
        'rateLimited',
        'protocol',
        'server',
        'invalidData',
        'validation',
        'unsupported',
        'unknown',
        'neverHeardOfIt',
      ];
      for (final locale in const [Locale('zh'), Locale('en')]) {
        final l10n = AppLocalizations(locale);
        for (final name in names) {
          expect(
            l10n.errorFor(name),
            isNotEmpty,
            reason: '${locale.languageCode} has no message for $name',
          );
        }
      }
    });
  });

  group('delegate', () {
    const delegate = AppLocalizations.delegate;

    test('supports both shipped languages', () {
      expect(delegate.isSupported(const Locale('zh')), isTrue);
      expect(delegate.isSupported(const Locale('en')), isTrue);
      expect(delegate.isSupported(const Locale('fr')), isFalse);
    });

    test('loads synchronously', () async {
      final l10n = await delegate.load(const Locale('en'));
      expect(l10n, isA<AppLocalizations>());
      expect(l10n.locale.languageCode, 'en');
    });

    test('never needs reloading', () {
      expect(
        delegate.shouldReload(AppLocalizations.delegate),
        isFalse,
      );
    });
  });
}
