import 'package:campus_atlas/core/i18n/app_localizations.dart';
import 'package:campus_atlas/features/grades_query/jwgl/jwgl_screen.dart';
import 'package:campus_atlas/main.dart';
import 'package:campus_atlas/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reproduces a blank 方正教务 screen through the **real navigation path**.
///
/// In a release build a throw during build looks exactly like a blank screen —
/// the error is swallowed rather than drawn — so these assert both that the
/// widget appears and that no exception was caught. The earlier version of this
/// file pushed the screen directly, which bypasses navigation and therefore
/// could not have reproduced the report at all.
///
/// Navigation is driven by *icon*, not by label: the test binding's locale may
/// be English, and matching on a Chinese label would silently find nothing.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const CampusAtlasApp());
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(AppScope).evaluate().isNotEmpty) return;
    }
    fail('AppScope never became available');
  }

  testWidgets('navigating from 更多 to 方正教务 renders content', (tester) async {
    await pumpApp(tester);
    expect(tester.takeException(), isNull);

    // The unselected nav icon; the selected one differs, which is why matching
    // on a label was unreliable.
    final moreTab = find.byIcon(Icons.explore_outlined);
    expect(moreTab, findsOneWidget,
        reason: 'the 更多 destination should be reachable');
    await tester.tap(moreTab);
    await tester.pumpAndSettle();

    expect(find.byType(MoreScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The 方正教务 tile shares its icon with the 课程 tile, so take the last
    // one rather than the first.
    final tiles = find.descendant(
      of: find.byType(MoreScreen),
      matching: find.byIcon(Icons.school_outlined),
    );
    expect(tiles, findsNWidgets(2),
        reason: '课程 and 方正教务 both use the school icon');
    await tester.tap(tiles.last);
    await tester.pumpAndSettle();

    expect(find.byType(JwglScreen), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'an exception here is exactly what a blank release screen '
            'means');

    // The wall must render actual content, not an empty scaffold.
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byIcon(Icons.login_rounded), findsOneWidget);
  });

  testWidgets(
      'every string the sign-in wall uses is non-empty, in every locale',
      (tester) async {
    // The earlier version of this checked one locale only. A missing or empty
    // value in the *other* locale is exactly the kind of gap that survives a
    // passing test and shows up for a user whose device is set to Chinese.
    for (final locale in AppLocalizations.supportedLocales) {
      final missing = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(builder: (context) {
            final l10n = AppLocalizations.of(context);
            final probes = <String, String>{
              'jw.title': l10n.jwTitle,
              'jw.signInNeeded': l10n.jwSignInNeeded,
              'jw.signInCta': l10n.jwSignInCta,
              'jw.explain': l10n.jwExplain,
              'jw.fetchMenu': l10n.jwFetchMenu,
              'jw.menuTitle': l10n.jwMenuTitle,
              'jw.emptyMenu': l10n.jwEmptyMenu,
              'jw.noEvaluation': l10n.jwNoEvaluation,
              'jw.foundEvaluation': l10n.jwFoundEvaluation,
              'jw.diagnosticsNote': l10n.jwDiagnosticsNote,
              'gq.diagnostics': l10n.gqDiagnostics,
              'gq.copy': l10n.gqCopy,
              'gq.copied': l10n.gqCopied,
              'gq.noRaw': l10n.gqNoRaw,
              'gq.clear': l10n.gqClear,
              'signInChallengeHint': l10n.signInChallengeHint,
            };
            for (final e in probes.entries) {
              if (e.value.trim().isEmpty) missing.add(e.key);
            }
            return const Placeholder();
          }),
        ),
      );
      await tester.pumpAndSettle();
      expect(missing, isEmpty,
          reason: 'missing or empty in ${locale.languageCode}: $missing');
    }
    expect(tester.takeException(), isNull);
  });
}
