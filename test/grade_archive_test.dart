import 'dart:convert';

import 'package:campus_atlas/core/storage/settings.dart';
import 'package:campus_atlas/features/grades_query/archive/grade_archive_repository.dart';
import 'package:campus_atlas/features/grades_query/archive/grade_models.dart';
import 'package:flutter_test/flutter_test.dart';

GradeRecord _rec({
  String year = '2025-2026',
  String semester = '1',
  String name = '高等数学A1',
  String code = 'MATH001',
  String teacher = '李老师',
  String kind = '必修',
  double credits = 4,
  String scoreText = '82',
  double? score = 82,
  double? point = 3.3,
  String source = 'jwgl',
}) =>
    GradeRecord(
      year: year,
      semester: semester,
      courseName: name,
      courseCode: code,
      teacher: teacher,
      courseKind: kind,
      credits: credits,
      scoreText: scoreText,
      score: score,
      gradePoint: point,
      source: source,
    );

void main() {
  group('GradeRecord', () {
    test('key prefers the course code and falls back to the name', () {
      expect(_rec(code: 'MATH001').key, '2025-2026|1|MATH001');
      expect(_rec(code: '').key, '2025-2026|1|高等数学A1');
    });

    test('academic year and term parse, including Chinese terms', () {
      expect(_rec().yearStart, 2025);
      expect(_rec(semester: '第一学期').semesterNumber, 1);
      expect(_rec(semester: '第二学期').semesterNumber, 2);
      expect(_rec(semester: '2').semesterNumber, 2);
      expect(_rec(year: '', semester: '').yearStart, 0);
      expect(_rec(year: '', semester: '').semesterNumber, 0);
    });

    test('the short term label is compact', () {
      expect(_rec().shortTermLabel, '25-26·1');
      expect(_rec(semester: '第二学期').shortTermLabel, '25-26·2');
    });

    test('term comparison orders by year then term', () {
      final early = _rec(year: '2024-2025', semester: '2');
      final late = _rec(year: '2025-2026', semester: '1');
      expect(GradeRecord.compare(early, late), lessThan(0));
      expect(GradeRecord.compare(late, early), greaterThan(0));
    });

    test('JSON round trip keeps every field', () {
      final record = _rec();
      final decoded =
          GradeRecord.fromJson(jsonDecode(jsonEncode(record.toJson())) as Map<String, Object?>);
      expect(decoded.requireValue, record);
    });

    test('JSON parse rejects a row without year/semester/name', () {
      expect(GradeRecord.fromJson(const {'courseName': 'x'}).isFailure, isTrue);
      expect(GradeRecord.fromJson(const {'year': '2025-2026'}).isFailure,
          isTrue);
    });
  });

  group('GradeArchiveRepository', () {
    // The storage key is pinned on purpose: renaming it in the repository
    // would silently orphan the grades a person already imported, so the test
    // fails when the literal changes.
    const key = 'grades.archive.v1';

    test('merge adds new rows and reports counts', () async {
      final store = InMemorySettingsStore();
      final repo = GradeArchiveRepository(store);

      final result = await repo.merge([_rec(), _rec(code: 'PHYS002', name: '大学物理')]);
      final merged = result.requireValue;

      expect(merged.added, 2);
      expect(merged.updated, 0);
      expect(merged.total, 2);

      final loaded = (await repo.load()).requireValue;
      expect(loaded.length, 2);
    });

    test('a re-import replaces a changed row instead of duplicating it',
        () async {
      final store = InMemorySettingsStore();
      final repo = GradeArchiveRepository(store);

      await repo.merge([_rec(scoreText: '55', score: 55, point: 0)]);
      final result =
          await repo.merge([_rec(scoreText: '82', score: 82, point: 3.3)]);
      final merged = result.requireValue;

      expect(merged.added, 0);
      expect(merged.updated, 1);
      expect(merged.total, 1);

      final loaded = (await repo.load()).requireValue;
      expect(loaded.single.score, 82);
    });

    test('an identical re-import changes nothing', () async {
      final store = InMemorySettingsStore();
      final repo = GradeArchiveRepository(store);

      await repo.merge([_rec()]);
      final result = await repo.merge([_rec()]);

      expect(result.requireValue.added, 0);
      expect(result.requireValue.updated, 0);
      expect(result.requireValue.changed, isFalse);
    });

    test('a duplicated key inside one import counts once', () async {
      final store = InMemorySettingsStore();
      final repo = GradeArchiveRepository(store);

      final result = await repo.merge([
        _rec(scoreText: '55', score: 55, point: 0),
        _rec(scoreText: '82', score: 82, point: 3.3),
      ]);

      expect(result.requireValue.added, 1);
      expect(result.requireValue.total, 1);
      expect((await repo.load()).requireValue.single.score, 82);
    });

    test('a corrupted archive reports a failure rather than throwing',
        () async {
      final store = InMemorySettingsStore();
      await store.setString(key, '{not json');
      final repo = GradeArchiveRepository(store);

      expect((await repo.load()).isFailure, isTrue);
      expect((await repo.merge([_rec()])).isFailure, isTrue);
    });

    test('one corrupted row does not take the whole archive down', () async {
      final store = InMemorySettingsStore();
      final good = _rec().toJson();
      await store.setString(
        key,
        jsonEncode([
          {'unexpected': true},
          good,
        ]),
      );
      final repo = GradeArchiveRepository(store);

      final loaded = (await repo.load()).requireValue;
      expect(loaded.single.courseName, '高等数学A1');
    });

    test('clear removes the local copy', () async {
      final store = InMemorySettingsStore();
      final repo = GradeArchiveRepository(store);

      await repo.merge([_rec()]);
      await repo.clear();

      expect((await repo.load()).requireValue, isEmpty);
    });

    test('remove deletes one row by key and answers the rest', () async {
      final store = InMemorySettingsStore();
      final repo = GradeArchiveRepository(store);
      await repo.merge([_rec(), _rec(code: 'PHYS002', name: '大学物理')]);

      final remaining = await repo.remove(_rec().key);

      expect(remaining.requireValue.single.courseName, '大学物理');
      expect((await repo.load()).requireValue.single.courseName, '大学物理');
    });
  });
}
