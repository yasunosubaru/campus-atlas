import 'dart:convert';

import 'package:campus_atlas/core/storage/settings.dart';
import 'package:campus_atlas/features/timetable/timetable_models.dart';
import 'package:campus_atlas/features/timetable/timetable_repository.dart';
import 'package:flutter_test/flutter_test.dart';

Course course({
  String id = 'c1',
  String name = '高等数学',
  int weekday = 1,
  int start = 1,
  int count = 2,
  Set<int> weeks = const {1, 2, 3},
}) =>
    Course(
      id: id,
      name: name,
      weekday: weekday,
      startPeriod: start,
      periodCount: count,
      weeks: weeks,
    );

void main() {
  late InMemorySettingsStore store;

  setUp(() => store = InMemorySettingsStore());

  group('migration from the single-timetable layout', () {
    test('an existing course list becomes the default timetable', () async {
      await store.setString(
        'timetable.courses',
        jsonEncode([course().toJson()]),
      );

      final repo = TimetableRepository(store);
      final profiles = (await repo.profiles()).requireValue;
      final courses = (await repo.load()).requireValue;

      expect(profiles, hasLength(1));
      expect(profiles.single.id, TimetableRepository.defaultProfileId);
      expect(profiles.single.name, isEmpty);
      expect(courses.single.name, '高等数学');
    });

    test('the legacy key is removed once the copy is written', () async {
      await store.setString(
        'timetable.courses',
        jsonEncode([course().toJson()]),
      );
      await TimetableRepository(store).profiles();

      expect(await store.getString('timetable.courses'), isEmpty);
      expect(
        await store.getString('timetable.courses.default'),
        isNotEmpty,
      );
    });

    test('a fresh store gets one empty default timetable', () async {
      final repo = TimetableRepository(store);
      expect((await repo.profiles()).requireValue, hasLength(1));
      expect((await repo.load()).requireValue, isEmpty);
    });
  });

  group('profiles', () {
    test('create adds a timetable and makes it active', () async {
      final repo = TimetableRepository(store);
      await repo.profiles();

      final created = (await repo.createProfile('辅修')).requireValue;
      expect(created.map((p) => p.name), ['', '辅修']);
      expect((await repo.activeProfileId()).requireValue, created.last.id);
    });

    test('a blank name is refused', () async {
      final repo = TimetableRepository(store);
      final result = await repo.createProfile('   ');
      expect(result.isFailure, isTrue);
    });

    test('rename changes only the named profile', () async {
      final repo = TimetableRepository(store);
      await repo.profiles();
      final created = (await repo.createProfile('辅修')).requireValue.last;

      final renamed =
          (await repo.renameProfile(created.id, '第二学位')).requireValue;
      expect(renamed.map((p) => p.name), ['', '第二学位']);
    });

    test('courses are stored per timetable and do not leak across', () async {
      final repo = TimetableRepository(store);
      await repo.profiles();
      await repo.add(course(id: 'main', name: '主课表课程'));

      final second = (await repo.createProfile('辅修')).requireValue.last;
      expect((await repo.load()).requireValue, isEmpty,
          reason: 'the new timetable starts empty');

      await repo.add(course(id: 'minor', name: '辅修课程'));
      expect((await repo.load()).requireValue.single.name, '辅修课程');

      await repo.setActiveProfile(TimetableRepository.defaultProfileId);
      expect((await repo.load()).requireValue.single.name, '主课表课程');

      // Switching back sees the minor timetable's own course again.
      await repo.setActiveProfile(second.id);
      expect((await repo.load()).requireValue.single.name, '辅修课程');
    });

    test('deleting a timetable removes its courses', () async {
      final repo = TimetableRepository(store);
      await repo.profiles();
      final second = (await repo.createProfile('辅修')).requireValue.last;
      await repo.add(course(id: 'minor'));

      final left = (await repo.deleteProfile(second.id)).requireValue;

      expect(left, hasLength(1));
      expect(await store.getString('timetable.courses.${second.id}'), isEmpty);
      // The active id falls back to a remaining profile.
      expect((await repo.activeProfileId()).requireValue,
          TimetableRepository.defaultProfileId);
    });

    test('the last timetable cannot be deleted', () async {
      final repo = TimetableRepository(store);
      await repo.profiles();

      final result =
          await repo.deleteProfile(TimetableRepository.defaultProfileId);
      expect(result.isFailure, isTrue);
      expect((await repo.profiles()).requireValue, hasLength(1));
    });

    test('an unknown active id falls back to the first profile', () async {
      final repo = TimetableRepository(store);
      await repo.profiles();
      await store.setString('timetable.activeProfile', 'gone');

      expect((await repo.activeProfileId()).requireValue,
          TimetableRepository.defaultProfileId);
    });
  });

  group('course updates', () {
    test('update replaces by id and keeps the rest', () async {
      final repo = TimetableRepository(store);
      await repo.add(course(id: 'a', name: 'A'));
      await repo.add(course(id: 'b', name: 'B'));

      final result = await repo.update(course(id: 'a', name: 'A2'));
      expect(result.requireValue.map((c) => c.name), ['A2', 'B']);
    });

    test('replaceAll is what an import uses', () async {
      final repo = TimetableRepository(store);
      await repo.add(course(id: 'old', name: '旧课'));

      final result = await repo.replaceAll([course(id: 'new', name: '新课')]);
      expect(result.requireValue.map((c) => c.id), ['new']);
      expect((await repo.load()).requireValue.single.id, 'new');
    });
  });

  group('TimetableProfile JSON', () {
    test('round-trips', () {
      const profile = TimetableProfile(id: 'p1', name: '辅修');
      final parsed = TimetableProfile.fromJson(profile.toJson());
      expect(parsed.requireValue.id, 'p1');
      expect(parsed.requireValue.name, '辅修');
    });

    test('rejects a missing id', () {
      expect(TimetableProfile.fromJson(const {'name': 'x'}).isFailure, isTrue);
    });
  });

  group('Course time fields', () {
    test('round-trip with times', () {
      const c = Course(
        id: 'c1',
        name: '物理',
        weekday: 2,
        startPeriod: 3,
        periodCount: 2,
        weeks: {1},
        startTime: '10:00',
        endTime: '11:40',
      );
      final parsed = Course.fromJson(c.toJson());
      expect(parsed.requireValue, c);
      expect(parsed.requireValue.startTime, '10:00');
    });

    test('a document without times parses with empty ones', () {
      final json = course().toJson()
        ..remove('startTime')
        ..remove('endTime');
      final parsed = Course.fromJson(json);
      expect(parsed.requireValue.startTime, isEmpty);
      expect(parsed.requireValue.endTime, isEmpty);
    });
  });
}
