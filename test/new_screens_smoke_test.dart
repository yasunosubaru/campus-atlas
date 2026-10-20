import 'dart:convert';

import 'package:campus_atlas/features/grades_query/archive/grade_models.dart';
import 'package:campus_atlas/features/timetable/timetable_models.dart';
import 'package:campus_atlas/main.dart';
import 'package:campus_atlas/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Navigation smoke tests for the screens added with items 3–7.
///
/// They go through the app's real shell rather than pushing widgets directly:
/// the failures these catch are wiring failures — a tile pointing at nothing, a
/// tab that throws on build, a sheet that needs a service the screen never got.
void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const CampusAtlasApp());
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(AppScope).evaluate().isNotEmpty) break;
    }
    expect(find.byType(AppScope), findsOneWidget);
    await tester.pumpAndSettle();
  }

  Future<void> openTab(WidgetTester tester, IconData icon) async {
    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.byIcon(icon),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openMoreTile(WidgetTester tester, IconData icon) async {
    await openTab(tester, Icons.explore_outlined);
    final tile = find.descendant(
      of: find.byType(MoreScreen),
      matching: find.byIcon(icon),
    );
    // 更多 is a lazy list: the lower tiles (map, chat, settings) are not built
    // until they are scrolled into view.
    await tester.scrollUntilVisible(
      tile,
      300,
      scrollable: find
          .descendant(
            of: find.byType(MoreScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  testWidgets('the timetable offers a week grid, a month view and an import',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // The legacy single-timetable key: it must migrate into the default
      // profile, otherwise this test would open an empty grid.
      'timetable.courses': jsonEncode([
        const Course(
          id: 'c1',
          name: '高等数学A1',
          weekday: 1,
          startPeriod: 1,
          periodCount: 2,
          weeks: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
            18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33,
            34, 35, 36, 37, 38, 39, 40},
          location: '教五-101',
        ).toJson(),
      ]),
    });

    await pumpApp(tester);
    await openTab(tester, Icons.calendar_month_outlined);

    expect(find.text('高等数学A1'), findsWidgets);
    expect(find.byKey(const ValueKey('timetable.week')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('月视图'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timetable.month')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('周视图'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timetable.week')), findsOneWidget);

    // The import sheet explains that a sign-in comes first, rather than
    // offering a button that can only fail.
    await tester.tap(find.descendant(
      of: find.byType(Scaffold),
      matching: find.byIcon(Icons.download_outlined),
    ));
    await tester.pumpAndSettle();
    expect(find.text('先完成一次账户登录（设置 → 账户登录），才能读取教务课表。'),
        findsOneWidget);
    expect(find.text('本科教务（N2151）'), findsOneWidget);
    expect(find.text('研究生系统'), findsOneWidget);
  });

  testWidgets('the map opens on the native campus view', (tester) async {
    await pumpApp(tester);
    await openMoreTile(tester, Icons.map_outlined);

    expect(find.byKey(const ValueKey('campus.map')), findsOneWidget);
    expect(find.textContaining('OpenStreetMap'), findsWidgets);
    expect(find.textContaining('个设施'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('地点搜索'));
    await tester.pumpAndSettle();
    expect(find.textContaining('搜索地点'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('academic standing is computed from the archive', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'grades.archive.v1': jsonEncode([
        const GradeRecord(
          year: '2025-2026',
          semester: '1',
          courseName: '高等数学A1',
          courseKind: '必修',
          credits: 3,
          scoreText: '90',
          score: 90,
        ).toJson(),
        const GradeRecord(
          year: '2025-2026',
          semester: '1',
          courseName: '通识课',
          courseKind: '选修',
          credits: 2,
          scoreText: '80',
          score: 80,
        ).toJson(),
      ]),
    });

    await pumpApp(tester);
    await openMoreTile(tester, Icons.workspace_premium_outlined);

    // (4.0×3 + 3.0×2) / 5 = 3.6
    expect(find.text('3.60'), findsOneWidget);
    expect(find.textContaining('已通过学分'), findsOneWidget);
    expect(find.text('必修'), findsOneWidget);
    expect(find.text('选修'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('academic standing explains an empty archive', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpApp(tester);
    await openMoreTile(tester, Icons.workspace_premium_outlined);

    expect(find.text('还没有成绩'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a review draft can be written and kept', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpApp(tester);
    await openMoreTile(tester, Icons.rate_review_outlined);

    expect(find.text('还没有草稿'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    final courseField = find.widgetWithText(TextField, '课程名称');
    expect(courseField, findsOneWidget);
    await tester.enterText(courseField, '高等数学A1');
    await tester.tap(find.widgetWithText(FilledButton, '保存草稿'));
    await tester.pumpAndSettle();

    expect(find.text('高等数学A1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('account sign-in lives in Settings', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpApp(tester);
    await openMoreTile(tester, Icons.settings_outlined);

    // The account section is the first thing in Settings.
    final accountTile = find.widgetWithText(ListTile, '账户登录');
    expect(accountTile, findsOneWidget);
    await tester.tap(accountTile);
    await tester.pumpAndSettle();

    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('在应用内浏览器登录'), findsOneWidget);
    expect(find.textContaining('二次认证'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Ham centre explains that authorisation comes first',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpApp(tester);
    await openMoreTile(tester, Icons.query_stats_outlined);

    // The Ham screen is open; its person button leads to the account centre.
    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();

    expect(find.text('需要先授权 Ham'), findsOneWidget);
    expect(find.textContaining('快捷授权'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
