import 'dart:convert';

import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/core/storage/settings.dart';
import 'package:campus_atlas/features/teaching_eval/review_drafts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemorySettingsStore store;
  late DateTime fixedNow;

  ReviewDraftRepository repo() =>
      ReviewDraftRepository(store, now: () => fixedNow);

  setUp(() {
    store = InMemorySettingsStore();
    fixedNow = DateTime(2026, 10, 19, 10);
  });

  ReviewDraft draft({
    String id = 'r1',
    String course = '高等数学A1',
    String teacher = '张三',
    int rating = 4,
    String text = '讲得清楚',
  }) =>
      ReviewDraft(
        id: id,
        courseName: course,
        teacher: teacher,
        rating: rating,
        text: text,
      );

  group('ReviewDraft', () {
    test('asText reads like a review', () {
      expect(draft().asText, '高等数学A1\n张三\n★★★★\n讲得清楚');
    });

    test('asText omits empty parts', () {
      const empty = ReviewDraft(id: 'r', courseName: '课');
      expect(empty.asText, '课');
    });

    test('JSON round-trips every field', () {
      final withTime = draft().copyWith(updatedAt: fixedNow);
      final parsed = ReviewDraft.fromJson(withTime.toJson());
      expect(parsed.requireValue.courseName, '高等数学A1');
      expect(parsed.requireValue.rating, 4);
      expect(parsed.requireValue.text, '讲得清楚');
      expect(parsed.requireValue.updatedAt, fixedNow);
    });

    test('an out-of-range rating is clamped when read', () {
      final parsed = ReviewDraft.fromJson(const {
        'id': 'r',
        'courseName': '课',
        'rating': 9,
      });
      expect(parsed.requireValue.rating, 5);
    });

    test('a row without an id or course name is rejected', () {
      expect(ReviewDraft.fromJson(const {'courseName': 'x'}).isFailure, isTrue);
      expect(ReviewDraft.fromJson(const {'id': 'r'}).isFailure, isTrue);
    });
  });

  group('ReviewDraftRepository', () {
    test('starts empty', () async {
      expect((await repo().list()).requireValue, isEmpty);
    });

    test('upsert inserts and stamps the update time', () async {
      final result = await repo().upsert(draft());
      final saved = result.requireValue.single;
      expect(saved.courseName, '高等数学A1');
      expect(saved.updatedAt, fixedNow);
    });

    test('upsert replaces the draft with the same id', () async {
      final repository = repo();
      await repository.upsert(draft());
      final result = await repository.upsert(draft(text: '改过了'));

      expect(result.requireValue, hasLength(1));
      expect(result.requireValue.single.text, '改过了');
    });

    test('a blank course name is refused', () async {
      final result = await repo().upsert(draft(course: '   '));
      expect(result.isFailure, isTrue);
      expect(result.errorOrNull?.kind, FailureKind.validation);
    });

    test('drafts are ordered newest first', () async {
      final repository = repo();
      await repository.upsert(draft(id: 'a', course: 'A'));
      fixedNow = fixedNow.add(const Duration(minutes: 1));
      await repository.upsert(draft(id: 'b', course: 'B'));

      expect(
        (await repository.list()).requireValue.map((d) => d.courseName),
        ['B', 'A'],
      );
    });

    test('remove drops one draft', () async {
      final repository = repo();
      await repository.upsert(draft(id: 'a', course: 'A'));
      await repository.upsert(draft(id: 'b', course: 'B'));

      final result = await repository.remove('a');
      expect(result.requireValue.map((d) => d.id), ['b']);
    });

    test('a draft survives a new repository over the same store', () async {
      await repo().upsert(draft());
      final after = await repo().list();
      expect(after.requireValue.single.courseName, '高等数学A1');
    });

    test('corrupt JSON is a typed failure', () async {
      await store.setString('reviews.drafts', '{not a list');
      final result = await repo().list();
      expect(result.isFailure, isTrue);
      expect(result.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('one unreadable row does not discard the rest', () async {
      await store.setString(
        'reviews.drafts',
        jsonEncode([
          {'id': 'a', 'courseName': 'A'},
          {'id': 42},
        ]),
      );
      final result = await repo().list();
      expect(result.requireValue.single.courseName, 'A');
    });
  });
}
