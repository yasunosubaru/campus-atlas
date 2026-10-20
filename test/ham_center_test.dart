import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/grades_query/ham/ham_center_models.dart';
import 'package:campus_atlas/features/grades_query/ham/ham_center_repository.dart';
import 'package:campus_atlas/features/grades_query/ham/ham_mcp_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A gateway that answers from fixtures, so the parsing and the argument
/// building are tested without a token or a network.
class FakeGateway implements HamToolGateway {
  FakeGateway({
    required this.tools,
    this.responses = const {},
    this.failures = const {},
  });

  final List<HamMcpTool> tools;
  final Map<String, Object?> responses;

  /// Tool name → the error text the server would have returned.
  final Map<String, String> failures;

  final Map<String, Map<String, Object?>> calls = {};

  @override
  Future<Result<List<HamMcpTool>>> listTools() async => Success(tools);

  @override
  Future<Result<Object?>> call(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) async {
    calls[name] = arguments;
    final failure = failures[name];
    if (failure != null) {
      return Failure<Object?>.reason(
        FailureKind.unauthorized,
        message: failure,
      );
    }
    final payload = responses[name];
    if (payload == null) {
      return Failure<Object?>.reason(
        FailureKind.unsupported,
        message: 'no fixture for $name',
      );
    }
    return Success(payload);
  }

  @override
  void close() {}
}

HamMcpTool tool(
  String name, {
  List<String> arguments = const [],
  List<String> required = const [],
}) =>
    HamMcpTool(
      name: name,
      description: '',
      inputSchema: {
        'properties': {
          for (final argument in arguments) argument: <String, Object?>{},
        },
        'required': required,
      },
    );

List<HamMcpTool> allTools() => [
      tool('get_user_info'),
      tool('get_course_comments',
          arguments: ['course_table_id', 'cursor'],
          required: ['course_table_id', 'cursor']),
      tool('get_semester_grade_stats',
          arguments: ['course_table_id', 'year', 'semester'],
          required: ['course_table_id', 'year', 'semester']),
      tool('get_score_rank', arguments: ['cursor'], required: ['cursor']),
      tool('get_course_want_list',
          arguments: ['cursor'], required: ['cursor']),
      tool('get_my_comments', arguments: ['cursor'], required: ['cursor']),
    ];

const _comment = {
  'author': 'A',
  'content': '讲得清楚',
  'create_time': '2026-10-01',
  'id': 7,
  'like_total': 3,
  'rate': 5,
};

void main() {
  group('models', () {
    test('a comment page reads total and the next cursor', () {
      final page = HamCommentPage.from({
        'comments': [_comment],
        'total': 8,
        'next_cursor': 'abc',
      });
      expect(page.comments, hasLength(1));
      expect(page.comments.single.author, 'A');
      expect(page.comments.single.rate, 5);
      expect(page.comments.single.likeTotal, 3);
      expect(page.total, 8);
      expect(page.nextCursor, 'abc');
    });

    test('an out-of-range rate is clamped', () {
      final comment = HamComment.tryParse({..._comment, 'rate': 9});
      expect(comment!.rate, 5);
    });

    test('a loose section reads rank_items and falls back on count', () {
      final section = HamLooseSection.from(
        {
          'rank_items': [
            {'name': '高等数学A1', 'rank': 3},
          ],
        },
        itemKeys: const ['rank_items'],
      );
      expect(section.total, 1);
      expect(section.items.single.title, '高等数学A1');
      expect(section.items.single.raw['rank'], 3);
    });

    test('a loose record reads a nested course name', () {
      final record = HamLooseRecord.from({
        'course': {'name': '大学物理', 'instructor': '李四'},
        'instructor': '李四',
      });
      expect(record.title, '大学物理');
      expect(record.subtitle, '李四');
    });

    test('a semester stat reads year, term and the distribution', () {
      final stat = HamSemesterStat.tryParse({
        'course': {'name': '高等数学A1', 'instructor': '张三'},
        'stat': {
          'average': 84.4,
          'median': 87,
          'total': 373,
          'year': 2025,
          'semester': 1,
          'range': [
            {'from': 0, 'to': 59, 'total': 21},
            {'from': 90, 'to': 100, 'total': 159},
          ],
        },
      });
      expect(stat, isNotNull);
      expect(stat!.year, 2025);
      expect(stat.semester, 1);
      expect(stat.course.name, '高等数学A1');
      expect(stat.course.average, 84.4);
      expect(stat.course.median, 87);
      expect(stat.course.buckets, hasLength(2));
    });

    test('a stat without a year is not accepted', () {
      final stat = HamSemesterStat.tryParse({
        'course': {'name': '课'},
        'stat': {'average': 80},
      });
      expect(stat, isNull);
    });
  });

  group('HamCenterRepository', () {
    FakeGateway gateway({
      Map<String, Object?> responses = const {},
      Map<String, String> failures = const {},
    }) =>
        FakeGateway(
          tools: allTools(),
          responses: {
            'get_user_info': {
              'avatar_url': 'https://example.invalid/a.png',
              'nickname': '小明',
              'user_id': 'u1',
            },
            'get_course_comments': {
              'comments': [_comment],
              'total': 8,
            },
            'get_my_comments': {
              'comments': [_comment],
              'total': 1,
            },
            'get_score_rank': {
              'rank_items': [
                {'name': '高等数学A1'},
              ],
              'total': 1,
            },
            'get_course_want_list': {
              'items': [
                {'course': {'name': '大学物理'}, 'instructor': '李四'},
              ],
              'total': 1,
            },
            'get_semester_grade_stats': {
              'course': {'name': '高等数学A1', 'instructor': '张三'},
              'stat': {
                'average': 84.4,
                'median': 87,
                'total': 373,
                'year': 2025,
                'semester': 1,
                'range': [
                  {'from': 0, 'to': 59, 'total': 21},
                ],
              },
            },
            ...responses,
          },
          failures: failures,
        );

    test('reads the profile', () async {
      final repo = HamCenterRepository(gateway: gateway());
      final result = await repo.userInfo();
      expect(result.requireValue.nickname, '小明');
      expect(result.requireValue.userId, 'u1');
    });

    test('reads comments with the documented arguments', () async {
      final fake = gateway();
      final repo = HamCenterRepository(gateway: fake);
      final result = await repo.comments('ct-1');

      expect(result.requireValue.total, 8);
      expect(result.requireValue.comments.single.content, '讲得清楚');
      expect(fake.calls['get_course_comments'], {
        'course_table_id': 'ct-1',
        'cursor': null,
      });
    });

    test('a blank course id is refused without a call', () async {
      final fake = gateway();
      final repo = HamCenterRepository(gateway: fake);
      final result = await repo.comments('  ');

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull?.kind, FailureKind.validation);
      expect(fake.calls, isEmpty);
    });

    test('passes a pagination cursor through', () async {
      final fake = gateway();
      final repo = HamCenterRepository(gateway: fake);
      await repo.myComments(cursor: 'page-2');

      expect(fake.calls['get_my_comments'], {'cursor': 'page-2'});
    });

    test('reads the semester statistics', () async {
      final fake = gateway();
      final repo = HamCenterRepository(gateway: fake);
      final result = await repo.semesterStat(
        courseTableId: 'ct-1',
        year: 2025,
        semester: 1,
      );

      expect(result.requireValue.year, 2025);
      expect(result.requireValue.course.total, 373);
      expect(fake.calls['get_semester_grade_stats'], {
        'course_table_id': 'ct-1',
        'year': 2025,
        'semester': 1,
      });
    });

    test('reads rank and want list as loose sections', () async {
      final repo = HamCenterRepository(gateway: gateway());
      final rank = await repo.scoreRank();
      final wants = await repo.wantList();

      expect(rank.requireValue.total, 1);
      expect(rank.requireValue.items.single.title, '高等数学A1');
      expect(wants.requireValue.items.single.title, '大学物理');
      expect(wants.requireValue.items.single.subtitle, '李四');
    });

    test('a tool-level error is surfaced verbatim', () async {
      final repo = HamCenterRepository(
        gateway: gateway(
          failures: {'get_user_info': '请重新登录'},
        ),
      );
      final result = await repo.userInfo();

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull?.message, contains('请重新登录'));
    });

    test('a missing tool names the tools that do exist', () async {
      final fake = FakeGateway(tools: [tool('something_else')]);
      final repo = HamCenterRepository(gateway: fake);
      final result = await repo.userInfo();

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull?.kind, FailureKind.unsupported);
      expect(result.errorOrNull?.message, contains('something_else'));
    });

    test('a required argument the caller cannot fill is a validation failure',
        () async {
      final fake = FakeGateway(
        tools: [
          tool(
            'get_course_comments',
            arguments: ['course_table_id', 'cursor', 'extra'],
            required: ['course_table_id', 'cursor', 'extra'],
          ),
        ],
      );
      final repo = HamCenterRepository(gateway: fake);
      final result = await repo.comments('ct-1');

      expect(result.errorOrNull?.kind, FailureKind.validation);
      expect(fake.calls, isEmpty);
    });
  });
}
