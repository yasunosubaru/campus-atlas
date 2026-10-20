import 'dart:convert';

import 'package:campus_atlas/core/widgets/common.dart';
import 'package:campus_atlas/features/grades_query/archive/gpa.dart';
import 'package:campus_atlas/features/grades_query/archive/grade_archive_screen.dart';
import 'package:campus_atlas/features/grades_query/archive/grade_models.dart';
import 'package:campus_atlas/features/grades_query/jwgl/jwgl_screen.dart';
import 'package:campus_atlas/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the archive screen through the app's real navigation path, with a
/// seeded archive and no network: the numbers it must show are arithmetic on
/// the fixture, so a wrong algorithm or a broken filter fails here rather than
/// being noticed by eye.
///
/// Rows and their hand-computed outcomes under the WHU table:
///   A 大学交际英语3  90 × 3 必修 → 4.0 → 12.0
///   B 通识课          80 × 2 选修 → 3.0 →  6.0
///   C 地球科学概论    85 × 3 必修 → 3.7 → 11.1
///
///   WHU, all:           (12.0 + 6.0 + 11.1) / 8 = 3.6375 → 3.64
///   WHU, required only: (12.0 + 11.1) / 6       = 3.85
///   5-point, all:       (4.0×3 + 3.0×2 + 3.5×3) / 8 = 3.5625 → 3.56
void main() {
  const storageKey = 'grades.archive.v1';

  GradeRecord row({
    required String year,
    required String semester,
    required String name,
    required String kind,
    required double credits,
    required String scoreText,
    required double score,
  }) =>
      GradeRecord(
        year: year,
        semester: semester,
        courseName: name,
        courseCode: name,
        courseKind: kind,
        credits: credits,
        scoreText: scoreText,
        score: score,
      );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: jsonEncode([
        row(
          year: '2025-2026',
          semester: '1',
          name: '大学交际英语3',
          kind: '必修',
          credits: 3,
          scoreText: '90',
          score: 90,
        ).toJson(),
        row(
          year: '2025-2026',
          semester: '1',
          name: '通识课',
          kind: '选修',
          credits: 2,
          scoreText: '80',
          score: 80,
        ).toJson(),
        row(
          year: '2024-2025',
          semester: '2',
          name: '地球科学概论',
          kind: '必修',
          credits: 3,
          scoreText: '85',
          score: 85,
        ).toJson(),
      ]),
    });
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const CampusAtlasApp());
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(AppScope).evaluate().isNotEmpty) break;
    }
    expect(find.byType(AppScope), findsOneWidget,
        reason: 'Services.create() must resolve before anything else is tried');
    await tester.pumpAndSettle();
  }

  Future<void> openArchive(WidgetTester tester) async {
    // Icons, not labels: the binding's locale is not the app's, and a Chinese
    // label match silently finds nothing when the frame is English.
    await tester.tap(find.byIcon(Icons.explore_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.school_outlined).last);
    await tester.pumpAndSettle();
    expect(find.byType(JwglScreen), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byType(JwglScreen),
      matching: find.byIcon(Icons.insights_outlined),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(GradeArchiveScreen), findsOneWidget);
  }

  testWidgets('the archive screen shows the GPA, the trend and the courses',
      (tester) async {
    await pumpApp(tester);
    await openArchive(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('3.64'), findsOneWidget,
        reason: 'WHU-weighted GPA of the fixture');

    // Both archived terms appear in the trend list, oldest first.
    expect(find.text('2024-2025 2'), findsOneWidget);
    expect(find.text('2025-2026 1'), findsOneWidget);

    // The course detail lists what was read, score included. It sits below the
    // fold, and a ListView builds lazily, so it has to be scrolled into being.
    await tester.scrollUntilVisible(find.text('大学交际英语3'), 300);
    expect(find.text('大学交际英语3'), findsOneWidget);
    expect(find.text('地球科学概论'), findsOneWidget);
    expect(find.text('90'), findsOneWidget);
  });

  testWidgets('switching the algorithm and the scope recomputes in place',
      (tester) async {
    await pumpApp(tester);
    await openArchive(tester);

    // The second segment is the 5-point standard, whatever the language.
    final segments = find.descendant(
      of: find.byType(SegmentedButton<GpaStandard>),
      matching: find.byType(Text),
    );
    expect(segments, findsNWidgets(3));
    await tester.tap(segments.at(1));
    await tester.pumpAndSettle();
    expect(find.text('3.56'), findsOneWidget,
        reason: '5-point GPA of the fixture');
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(find.text('3.75'), findsOneWidget,
        reason: '5-point, compulsory only: (4.0×3 + 3.5×3) / 6');
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty archive explains where grades come from',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpApp(tester);
    await openArchive(tester);

    expect(find.byType(EmptyState), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a manually added grade joins the statistics and can be removed',
      (tester) async {
    await pumpApp(tester);
    await openArchive(tester);

    Future<void> typeInto(String label, String value) async {
      final field = find.widgetWithText(TextField, label);
      expect(field, findsOneWidget, reason: 'the field labelled $label');
      await tester.enterText(field, value);
    }

    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();

    // The term pre-fills from the newest archived row (2025-2026 · 1).
    await typeInto('课程名称', '交流课程');
    await typeInto('学分', '1');
    await typeInto('成绩', '90');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    // (29.1 + 4.0) / 9 = 3.677… → 3.68
    expect(find.text('3.68'), findsOneWidget,
        reason: 'the manual grade joins the weighted mean');

    // It is marked as manual and can be taken back out.
    await tester.scrollUntilVisible(find.text('交流课程'), 300);
    expect(find.textContaining('手工'), findsWidgets);

    // The delete button is at the end of the row, which can still be outside
    // the viewport after scrolling to the name — a tap there would miss it.
    final remove = find.byIcon(Icons.remove_circle_outline);
    await tester.ensureVisible(remove);
    await tester.pumpAndSettle();
    await tester.tap(remove);
    await tester.pumpAndSettle();

    expect(find.text('交流课程'), findsNothing);
    await tester.scrollUntilVisible(find.text('3.64'), -300);
    expect(find.text('3.64'), findsOneWidget,
        reason: 'removing the manual grade restores the imported GPA');
    expect(tester.takeException(), isNull);
  });
}
