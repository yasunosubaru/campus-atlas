import 'package:campus_atlas/main.dart';
import 'package:campus_atlas/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Smoke tests for the composition root.
///
/// `flutter_test` blocks dart:io HTTP, so every remote call in these tests
/// fails. That is the point: the app must assemble, render the shell, and
/// degrade to a retryable error state rather than throw. Remote behaviour is
/// covered by the unit tests instead.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// Pumps the app and waits until the FutureBuilder has resolved Services.
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const CampusAtlasApp());
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(AppScope).evaluate().isNotEmpty) return;
    }
    fail('AppScope never became available — Services.create() did not resolve');
  }

  testWidgets('assembles dependencies and renders the navigation shell',
      (tester) async {
    await pumpApp(tester);

    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the home tab with the app title', (tester) async {
    await pumpApp(tester);
    expect(find.text('Campus Atlas'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('moves to another tab when its destination is tapped',
      (tester) async {
    await pumpApp(tester);

    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.selectedIndex, 0);

    await tester.tap(find.text('课表'));
    await tester.pump(const Duration(milliseconds: 300));

    final after = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(after.selectedIndex, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('survives remote failure without an unhandled exception',
      (tester) async {
    await pumpApp(tester);
    await tester.pump(const Duration(seconds: 3));

    expect(tester.takeException(), isNull);
    expect(find.byType(AppShell), findsOneWidget);
  });

  testWidgets('master timetable offers the clash filter', (tester) async {
    await pumpApp(tester);

    // Route and tab transitions need one frame to start and a second to
    // finish; a single pump leaves the animation at t=0.
    Future<void> tapAndSettle(Finder finder) async {
      await tester.tap(finder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await tapAndSettle(find.text('更多'));
    await tapAndSettle(find.text('课程'));
    await tapAndSettle(find.text('总课表'));

    expect(find.text('只看不冲突的课'), findsOneWidget);

    await tapAndSettle(find.text('只看不冲突的课'));

    expect(tester.takeException(), isNull);
  });
}
