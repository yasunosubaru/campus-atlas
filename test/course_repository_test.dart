import 'dart:convert';

import 'package:campus_atlas/core/network/api_client.dart';
import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/courses/course_models.dart';
import 'package:campus_atlas/features/courses/course_repository.dart';
import 'package:campus_atlas/features/timetable/timetable_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Fixtures below are **verbatim rows from live 200 responses** captured from
/// the public course service, not hand-written guesses. If the upstream field
/// set changes, these tests are what should fail first.
void main() {
  // ------------------------------------------------------------- fixtures

  final realCourseRow = <String, Object?>{
    '_type': 'courses',
    'attendance_policy': '',
    'average_course_interest': 0,
    'average_difficulty': 0,
    'average_rating': 0,
    'average_rating_difficult': 0,
    'average_teaching_quality': 0,
    'average_workload': 0,
    'capacity': 0,
    'class_room': '',
    'class_time': '',
    'code': 'HAM-4c7cecfde74a52cc',
    'course_content': '',
    'course_type': '',
    'course_uid': '01a0bda9-5a6f-7ad5-bdd5-e0d70e995f1b',
    'created_at': '2026-09-20T07:13:07.695717Z',
    'credits': 0,
    'department': 'HAM',
    'description': '',
    'elective_field': '',
    'exam_method': '',
    'grading_method': '',
    'name': '商务决策模型（课程设计）',
    'name_pinyin': '',
    'name_pinyin_initial': '',
    'prerequisites': '',
    'public_uid': '01a0bda9-5a6f-7ad5-bdd5-e0d70e995f1b',
    'relevance_score': 0.35384616255760193,
    'review_count': 0,
    'semester': '',
    'updated_at': '2026-09-20T07:13:07.695717Z',
  };

  final realSearchEnvelope = <String, Object?>{
    'success': true,
    'results': {
      'courses': [realCourseRow],
    },
    'total': 1,
    'page': 1,
    'limit': 20,
    'engine_type': 'hybrid',
    'query': '课程',
    'scope': 'global',
  };

  final realMasterRow = <String, Object?>{
    'id': 399861,
    'course_uid': '',
    'source_key':
        'c6267ed1a3377b86fce455901cb5076fe0145af144dbbde1a2f5913363bdb4dc',
    'teaching_class_id': '5600AE230234B89AE0630107010A3C7E02088124',
    'created_at': '2026-10-08T00:49:45.396199Z',
    'updated_at': '2026-10-08T00:49:45.396199Z',
    'name': '20世纪俄罗斯文学专题',
    'name_raw': '20世纪俄罗斯文学专题',
    'code': '3350130015',
    'teacher_name': '乐音',
    'teacher_name_raw': '乐音',
    'teacher_id': '',
    'course_type': '专业教育选修',
    'department': '外国语言文学学院',
    'credits': 2,
    'total_hours': 0,
    'campus': '1',
    'building': '1',
    'room': '新外-16',
    'day_of_week': 3,
    'start_section': 6,
    'end_section': 7,
    'weeks': '1-4,6-16',
    'semester': '3',
    'year': 2026,
  };

  final realPeriods = <String, Object?>{
    'periods': [
      {
        'year': 2026,
        'semester': '3',
        'revision': '01a118fb-1ef8-74eb-b35b-6fab7977314d',
        'stored_count': 13933,
        'published_at': '2026-10-08T00:49:47.136032Z',
      },
      {
        'year': 2025,
        'semester': '3',
        'revision': 'archive-2025-3',
        'stored_count': 12806,
        'published_at': '2026-07-27T20:07:33Z',
      },
      {
        'year': 2025,
        'semester': '12',
        'revision': 'archive-2025-12',
        'stored_count': 11751,
        'published_at': '2026-07-27T20:07:33Z',
      },
      {
        'year': 2025,
        'semester': '16',
        'revision': 'archive-2025-16',
        'stored_count': 2210,
        'published_at': '2026-07-27T20:07:33Z',
      },
    ],
  };

  // ------------------------------------------------------------- harness

  CourseRepository repoReturning(
    Object body, {
    int status = 200,
    String contentType = 'application/json',
    void Function(http.Request request)? onRequest,
  }) {
    final client = ApiClient(
      httpClient: MockClient((request) async {
        onRequest?.call(request);
        return http.Response(
          body is String ? body : jsonEncodeShim(body),
          status,
          headers: {'content-type': contentType},
        );
      }),
      maxRetries: 0,
    );
    return CourseRepository(client: client);
  }

  group('CourseSummary', () {
    test('parses the live row verbatim', () {
      final r = CourseSummary.fromJson(realCourseRow);
      expect(r.isSuccess, isTrue);
      final c = r.requireValue;
      expect(c.name, '商务决策模型（课程设计）');
      expect(c.code, 'HAM-4c7cecfde74a52cc');
      expect(c.uid, '01a0bda9-5a6f-7ad5-bdd5-e0d70e995f1b');
      expect(c.department, 'HAM');
      expect(c.rating.relevanceScore, closeTo(0.3538, 0.001));
    });

    test('rejects a row missing course_uid', () {
      final r = CourseSummary.fromJson(const {'name': 'x'});
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });
  });

  group('CourseRating', () {
    test('the live service currently returns all-zero aggregates', () {
      final rating = CourseRating.fromJson(realCourseRow);
      expect(rating.reviewCount, 0);
      expect(rating.isEmpty, isTrue);
      expect(rating.hasReviews, isFalse);
      expect(rating.rating, 0);
    });

    test('reads populated aggregates when reviews exist', () {
      final rating = CourseRating.fromJson(const {
        'average_rating': 4.5,
        'average_difficulty': 3.0,
        'average_teaching_quality': 4.2,
        'average_workload': 2.5,
        'average_course_interest': 4.0,
        'average_rating_difficult': 3.8,
        'review_count': 17,
      });
      expect(rating.hasReviews, isTrue);
      expect(rating.rating, 4.5);
      expect(rating.teachingQuality, 4.2);
      expect(rating.reviewCount, 17);
    });

    test('missing rating fields degrade to zero rather than throwing', () {
      final rating = CourseRating.fromJson(const {});
      expect(rating.isEmpty, isTrue);
      expect(rating.rating, 0);
    });
  });

  group('searchCourses', () {
    test('unwraps the nested results.courses envelope', () async {
      final repo = repoReturning(realSearchEnvelope);
      final r = await repo.searchCourses('课程');

      expect(r.isSuccess, isTrue);
      final page = r.requireValue;
      expect(page.items, hasLength(1));
      expect(page.items.single.name, '商务决策模型（课程设计）');
      expect(page.total, 1);
      expect(page.page, 1);
      // engine_type / scope are preserved for display
      expect(page.extra['engine_type'], 'hybrid');
      expect(page.extra['scope'], 'global');
    });

    test('sends the query under the name the service expects', () async {
      late Uri seen;
      final repo =
          repoReturning(realSearchEnvelope, onRequest: (r) => seen = r.url);
      await repo.searchCourses('高数');

      // The 422 we observed proved the parameter is `query`, not `q`.
      expect(seen.queryParameters['query'], '高数');
      expect(seen.queryParameters.containsKey('q'), isFalse);
      expect(seen.path, '/api/v1/search/simple');
    });

    test('rejects an empty query before touching the network', () async {
      var called = false;
      final repo =
          repoReturning(realSearchEnvelope, onRequest: (_) => called = true);
      final r = await repo.searchCourses('   ');

      expect(r.errorOrNull?.kind, FailureKind.validation);
      expect(called, isFalse);
    });

    test('reports invalidData when results.courses is absent', () async {
      final repo = repoReturning(const {'success': true, 'total': 0});
      final r = await repo.searchCourses('x');
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('surfaces a 401 as unauthorized', () async {
      final repo = repoReturning(
        '{"status":401,"title":"Unauthorized","code":"UNAUTHORIZED"}',
        status: 401,
      );
      final r = await repo.searchCourses('x');
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
      expect(r.errorOrNull?.statusCode, 401);
    });
  });

  group('suggestCourses', () {
    test('reads suggestions[]', () async {
      final repo = repoReturning(const {
        'suggestions': ['高等数学D', '高力', '高洵'],
        'query': '高数',
      });
      final r = await repo.suggestCourses('高数');
      expect(r.requireValue, ['高等数学D', '高力', '高洵']);
    });

    test('rejects an empty query locally', () async {
      final repo = repoReturning(const {'suggestions': <String>[]});
      final r = await repo.suggestCourses('');
      expect(r.errorOrNull?.kind, FailureKind.validation);
    });
  });

  group('masterTerms', () {
    test('parses and orders newest-first with correct term order', () async {
      final repo = repoReturning(realPeriods);
      final r = await repo.masterTerms();
      expect(r.isSuccess, isTrue);

      final terms = r.requireValue;
      expect(terms, hasLength(4));

      // 2026 autumn first.
      expect(terms.first.year, 2026);
      expect(terms.first.term, Term.autumn);
      expect(terms.first.storedCount, 13933);
      expect(
        terms.first.publishedAt,
        DateTime.parse('2026-10-08T00:49:47.136032Z'),
      );

      // Within 2025 the order must be autumn, winter, summer.
      // A lexical sort of "12","16","3" would wrongly yield 12, 16, 3.
      final y2025 = terms.where((t) => t.year == 2025).toList();
      expect(
        y2025.map((t) => t.term),
        [Term.autumn, Term.winter, Term.summer],
      );
    });

    test('reports invalidData when periods[] is absent', () async {
      final repo = repoReturning(const {'nope': true});
      final r = await repo.masterTerms();
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });
  });

  group('searchMasterTimetable', () {
    test('parses the live master row', () async {
      final repo = repoReturning({
        'items': [realMasterRow],
        'total': 1,
        'page': 1,
        'limit': 20,
        'has_more': false,
        'revision': 'rev-1',
      });
      final r = await repo.searchMasterTimetable(
        year: 2026,
        term: Term.autumn,
      );

      expect(r.isSuccess, isTrue);
      final c = r.requireValue.items.single;
      expect(c.id, 399861);
      expect(c.name, '20世纪俄罗斯文学专题');
      expect(c.teacherName, '乐音');
      expect(c.department, '外国语言文学学院');
      expect(c.room, '新外-16');
      expect(c.credits, 2);
      expect(c.dayOfWeek, 3);
      expect(c.startSection, 6);
      expect(c.endSection, 7);
      expect(c.weeks, '1-4,6-16');
      expect(c.year, 2026);
      expect(c.semester, '3');
    });

    test("the service's week expression parses with our own parser", () async {
      // The single most important interop fact: the upstream `weeks` grammar
      // and our timetable parser are the same language.
      final repo = repoReturning({
        'items': [realMasterRow],
        'total': 1,
      });
      final c =
          (await repo.searchMasterTimetable(year: 2026, term: Term.autumn))
              .requireValue
              .items
              .single;

      final weeks = parseWeeks(c.weeks);
      expect(weeks.isSuccess, isTrue);
      expect(weeks.requireValue.length, 15); // 1-4 and 6-16
      expect(weeks.requireValue.contains(1), isTrue);
      expect(weeks.requireValue.contains(5), isFalse,
          reason: 'week 5 excluded');
      expect(weeks.requireValue.contains(16), isTrue);
    });

    test('always sends year and semester; omits q when blank', () async {
      late Uri seen;
      final repo = repoReturning(const {'items': <Object?>[], 'total': 0},
          onRequest: (r) => seen = r.url);

      await repo.searchMasterTimetable(year: 2026, term: Term.summer);
      expect(seen.queryParameters['year'], '2026');
      expect(seen.queryParameters['semester'], '16');
      expect(seen.queryParameters.containsKey('q'), isFalse);

      await repo.searchMasterTimetable(
          year: 2025, term: Term.winter, query: '高数');
      expect(seen.queryParameters['semester'], '12');
      expect(seen.queryParameters['q'], '高数');
    });

    test('skips a malformed row instead of failing the page', () async {
      final repo = repoReturning({
        'items': [
          realMasterRow,
          <String, Object?>{'id': 'not-an-int'},
        ],
        'total': 2,
      });
      final r = await repo.searchMasterTimetable(year: 2026, term: Term.autumn);
      expect(r.isSuccess, isTrue);
      expect(r.requireValue.items, hasLength(1));
    });
  });

  group('Term', () {
    test('round-trips the academic system codes', () {
      expect(Term.fromCode('3'), Term.autumn);
      expect(Term.fromCode('12'), Term.winter);
      expect(Term.fromCode('16'), Term.summer);
      expect(Term.fromCode('99'), isNull);
    });
  });
}

/// Local JSON helper so the mock handler accepts a Map literal.
String jsonEncodeShim(Object? body) => jsonEncode(body);
