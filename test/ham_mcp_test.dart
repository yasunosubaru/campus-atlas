import 'dart:convert';

import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/grades_query/ham/ham_grades_repository.dart';
import 'package:campus_atlas/features/grades_query/ham/ham_mcp_client.dart';
import 'package:campus_atlas/features/grades_query/ham/ham_score_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A stand-in for Ham's MCP service.
///
/// It speaks just enough of Streamable HTTP to be meaningful: JSON-RPC over POST,
/// `tools/list`, `tools/call`, and both a JSON body and an SSE stream, because the
/// transport allows either per response and only handling one is how a client
/// works until the day the server switches.
class _FakeHam {
  _FakeHam({
    required this.tools,
    this.callResult,
    this.sse = false,
    this.unauthorized = false,
    this.toolError = false,
  });

  final List<Map<String, Object?>> tools;
  final Object? callResult;
  final bool sse;
  final bool unauthorized;
  final bool toolError;

  final List<http.Request> seen = [];
  int initializes = 0;
  int calls = 0;
  Map<String, Object?>? lastArguments;
  String? lastToolName;

  http.Client get client => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    seen.add(request);
    if (unauthorized) {
      return http.Response('{"error":"missing authorization token"}', 401);
    }

    final body = jsonDecode(request.body) as Map<String, Object?>;
    final method = '${body['method']}';
    final id = body['id'];

    // A notification has no id and gets no reply.
    if (method.startsWith('notifications/')) {
      return http.Response('', 202);
    }

    switch (method) {
      case 'initialize':
        initializes++;
        return _reply(id, {
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{},
          'serverInfo': {'name': 'ham', 'version': '1'},
        });
      case 'tools/list':
        return _reply(id, {'tools': tools});
      case 'tools/call':
        calls++;
        final params = body['params'] as Map<String, Object?>? ?? {};
        lastToolName = '${params['name']}';
        lastArguments =
            (params['arguments'] as Map?)?.cast<String, Object?>() ?? {};
        if (toolError) {
          return _reply(id, {
            'isError': true,
            'content': [
              {'type': 'text', 'text': 'not found'},
            ],
          });
        }
        return _reply(id, {
          'structuredContent': callResult,
          'content': [
            {'type': 'text', 'text': jsonEncode(callResult)},
          ],
        });
      default:
        return _reply(id, <String, Object?>{});
    }
  }

  http.Response _reply(Object? id, Map<String, Object?> result) {
    final envelope = {'jsonrpc': '2.0', 'id': id, 'result': result};
    if (!sse) {
      return http.Response(jsonEncode(envelope), 200, headers: {
        'content-type': 'application/json',
      });
    }
    // SSE: the message rides in `data:` frames.
    final stream = 'event: message\n'
        'data: ${jsonEncode(envelope)}\n\n';
    return http.Response(stream, 200, headers: {
      'content-type': 'text/event-stream',
    });
  }
}

/// The `score/stat` shape the gateway's own handler produces.
Map<String, Object?> statPayload() => {
      'name': '数字信号处理',
      'instructor': '张三',
      'average': 82.4,
      'total': 37,
      'range': [
        {'from': 90, 'to': 100, 'total': 9, 'color': '#4caf50'},
        {'from': 80, 'to': 89, 'total': 17, 'color': '#8bc34a'},
        {'from': 70, 'to': 79, 'total': 8, 'color': '#ffc107'},
        {'from': 60, 'to': 69, 'total': 3, 'color': '#ff9800'},
      ],
    };

/// The `score/by-course` shape: a list of teaching teams.
Map<String, Object?> byCoursePayload() => {
      'items': [
        {
          'id': 'aaa',
          'name': '数字信号处理',
          'instructor': '张三',
          'average': 82.4,
          'total': 37,
          'range': [
            {'from': 90, 'to': 100, 'total': 9, 'color': '#4caf50'},
          ],
        },
        {
          'id': 'bbb',
          'name': '数字信号处理',
          'instructor': '李四',
          'average': 76.1,
          'total': 22,
          'range': [
            {'from': 90, 'to': 100, 'total': 2, 'color': '#4caf50'},
          ],
        },
      ],
      'page_num': 0,
      'has_more': false,
    };

const List<Map<String, Object?>> _scoreTool = [
  {
    'name': 'ham_search_course',
    'description': 'Search courses by keyword.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'keyword': {'type': 'string'},
      },
      'required': ['keyword'],
    },
  },
  {
    'name': 'ham_course_score',
    'description':
        'Get the score distribution of a course, optionally narrowed to an instructor.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'course_name': {'type': 'string'},
        'instructor': {'type': 'string'},
        'page_num': {'type': 'integer'},
        'page_size': {'type': 'integer'},
      },
      'required': ['course_name'],
    },
  },
];

void main() {
  group('the MCP handshake', () {
    test('initializes once, then lists tools', () async {
      final ham = _FakeHam(tools: _scoreTool, callResult: statPayload());
      final client = HamMcpClient(apiKey: 'k', httpClient: ham.client);

      final tools = await client.listTools();
      await client.listTools();

      expect(tools.isSuccess, isTrue);
      expect(tools.requireValue, hasLength(2));
      // One handshake, not one per call: the session is stateful and re-initializing
      // it mid-conversation is how a server starts refusing requests.
      expect(ham.initializes, 1);
    });

    test('sends the key as a bearer token', () async {
      final ham = _FakeHam(tools: _scoreTool);
      final client =
          HamMcpClient(apiKey: 'secret-key-123', httpClient: ham.client);
      await client.listTools();

      expect(ham.seen.first.headers['authorization'], 'Bearer secret-key-123');
    });

    test('accepts both transports', () async {
      // The transport lets the server answer either way, per response.
      final ham = _FakeHam(tools: _scoreTool);
      await HamMcpClient(apiKey: 'k', httpClient: ham.client).listTools();
      expect(ham.seen.first.headers['accept'], contains('application/json'));
      expect(ham.seen.first.headers['accept'], contains('text/event-stream'));
    });

    test('reads a tool list delivered as an SSE stream', () async {
      final ham = _FakeHam(tools: _scoreTool, sse: true);
      final tools =
          await HamMcpClient(apiKey: 'k', httpClient: ham.client).listTools();

      expect(tools.isSuccess, isTrue);
      expect(
          tools.requireValue.map((t) => t.name), contains('ham_course_score'));
    });

    test('a refused key is reported as a key problem, not a protocol one',
        () async {
      final ham = _FakeHam(tools: _scoreTool, unauthorized: true);
      final r =
          await HamMcpClient(apiKey: 'k', httpClient: ham.client).listTools();

      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
      expect(r.errorOrNull?.message, contains('API key'));
      // The key must not be echoed back into an error message.
      expect(r.errorOrNull?.message, isNot(contains('secret-key-123')));
    });

    test('toString does not expose the key', () {
      final client = HamMcpClient(
        apiKey: 'secret-key-123',
        httpClient: _FakeHam(tools: _scoreTool).client,
      );
      expect(client.toString(), isNot(contains('secret-key-123')));
    });

    test('an empty body is a protocol failure, not an empty tool list',
        () async {
      final client = HamMcpClient(
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('', 200)),
      );
      final r = await client.listTools();
      expect(r.errorOrNull?.kind, FailureKind.protocol);
    });
  });

  group('choosing the score tool', () {
    test('picks the score tool out of a mixed list', () async {
      final ham = _FakeHam(tools: _scoreTool, callResult: byCoursePayload());
      final repo = HamGradesRepository(
        client: HamMcpClient(apiKey: 'k', httpClient: ham.client),
      );

      final r = await repo.search(query: '数字信号处理');

      expect(r.isSuccess, isTrue);
      expect(ham.lastToolName, 'ham_course_score');
      expect(repo.chosenTool?.name, 'ham_course_score');
    });

    test('does not pick a tool that merely mentions scores', () async {
      // A course *search* tool mentions "course" and matches on nothing else; the
      // score lookup must also name the thing being looked up.
      final ham = _FakeHam(
        tools: const [
          {
            'name': 'ham_search_course',
            'description': 'Search courses by keyword.',
            'inputSchema': {
              'type': 'object',
              'properties': {
                'keyword': {'type': 'string'},
              },
            },
          },
        ],
      );
      final repo = HamGradesRepository(
        client: HamMcpClient(apiKey: 'k', httpClient: ham.client),
      );
      final r = await repo.search(query: 'x');

      expect(r.errorOrNull?.kind, FailureKind.unsupported);
      expect(r.errorOrNull?.message, contains('ham_search_course'));
    });

    test('fills the course argument it discovered, not a guessed name',
        () async {
      final ham = _FakeHam(tools: _scoreTool, callResult: byCoursePayload());
      final repo = HamGradesRepository(
        client: HamMcpClient(apiKey: 'k', httpClient: ham.client),
      );
      await repo.search(query: '数字信号处理');

      expect(ham.lastArguments?['course_name'], '数字信号处理');
      // A page size is sent because the tool declares one.
      expect(ham.lastArguments?['page_size'], 50);
    });

    test('a query by instructor fills the instructor argument', () async {
      // This tool does not require a course name, so an instructor-only query can
      // satisfy it. With `_scoreTool` (course_name required) the same call is
      // correctly refused before it is sent — see the required-argument test.
      final ham = _FakeHam(tools: const [
        {
          'name': 'ham_instructor_score',
          'description':
              'Score distribution by instructor name, across their courses.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'instructor': {'type': 'string'},
            },
            'required': ['instructor'],
          },
        },
      ], callResult: statPayload());
      final repo = HamGradesRepository(
        client: HamMcpClient(apiKey: 'k', httpClient: ham.client),
      );
      await repo.search(query: '张三', kind: HamScoreQueryKind.byInstructor);

      expect(ham.lastArguments?['instructor'], '张三');
    });

    test('an instructor query against a course-only tool is refused locally',
        () async {
      // The gateway's `score/stat` needs both course and instructor, so there is
      // no way to satisfy it from a teacher's name alone. Sending it anyway would
      // earn a 400 that reads like a client bug.
      final ham = _FakeHam(tools: _scoreTool, callResult: statPayload());
      final repo = HamGradesRepository(
        client: HamMcpClient(apiKey: 'k', httpClient: ham.client),
      );
      final r =
          await repo.search(query: '张三', kind: HamScoreQueryKind.byInstructor);

      expect(r.isFailure, isTrue);
      expect(ham.calls, 0);
    });

    test('an empty query never reaches the network', () async {
      final ham = _FakeHam(tools: _scoreTool);
      final repo = HamGradesRepository(
        client: HamMcpClient(apiKey: 'k', httpClient: ham.client),
      );
      final r = await repo.search(query: '   ');

      expect(r.errorOrNull?.kind, FailureKind.validation);
      expect(ham.seen, isEmpty);
    });
  });

  group('reading the distribution', () {
    test('parses the single-course shape the gateway produces', () {
      final scores = HamCourseScore.listFrom(statPayload());

      expect(scores, hasLength(1));
      final s = scores.single;
      expect(s.name, '数字信号处理');
      expect(s.instructor, '张三');
      expect(s.average, 82.4);
      expect(s.total, 37);
      expect(s.buckets, hasLength(4));
      expect(s.buckets.first.from, 90);
      expect(s.buckets.first.total, 9);
      expect(s.busiestBucket, 17);
    });

    test('parses the by-course shape with several teaching teams', () {
      final scores = HamCourseScore.listFrom(byCoursePayload());

      expect(scores, hasLength(2));
      expect(scores.map((s) => s.instructor), ['张三', '李四']);
      expect(scores.first.id, 'aaa');
    });

    test('accepts camelCase as well as snake_case field names', () {
      // protobuf's JSON mapping is lowerCamelCase while the proto file is
      // snake_case, so which arrives is the server's serialiser's choice.
      final scores = HamCourseScore.listFrom({
        'courseName': '数字信号处理',
        'instructorName': '张三',
        'average': 80,
        'total': 5,
        'range': [
          {'from': 90, 'to': 100, 'total': 1},
        ],
      });

      expect(scores.single.name, '数字信号处理');
      expect(scores.single.instructor, '张三');
      expect(scores.single.buckets.single.to, 100);
    });

    test('the gateway\'s empty shape is recognised as empty, not as data', () {
      // This is what `score/stat` answers when the pair has no data: a 200 with
      // every field zeroed. Reading it as a course would show a blank card that
      // looks like a rendering bug.
      final scores = HamCourseScore.listFrom({
        'name': '',
        'instructor': '',
        'average': 0,
        'total': 0,
        'range': <Object?>[],
      });

      expect(scores.isEmpty, isTrue,
          reason: 'a payload with no name and no instructor is not a course');
    });

    test('a non-empty distribution is not reported as empty', () {
      expect(HamCourseScore.listFrom(statPayload()).single.isEmpty, isFalse);
    });

    test('an unknown envelope yields no scores rather than throwing', () {
      expect(HamCourseScore.listFrom({'something': 'else'}), isEmpty);
      expect(HamCourseScore.listFrom('nonsense'), isEmpty);
      expect(HamCourseScore.listFrom(null), isEmpty);
    });

    test('bands keep their own counts and colour', () {
      final s = HamCourseScore.listFrom(statPayload()).single;
      final band = s.buckets.firstWhere((b) => b.from == 80);

      expect(band.to, 89);
      expect(band.total, 17);
      expect(band.color, '#8bc34a');
    });
  });

  group('failures are told apart', () {
    test('a tool-level error is reported as a server failure', () async {
      final ham = _FakeHam(tools: _scoreTool, toolError: true);
      final repo = HamGradesRepository(
        client: HamMcpClient(apiKey: 'k', httpClient: ham.client),
      );
      final r = await repo.search(query: 'x');

      expect(r.errorOrNull?.kind, FailureKind.server);
      expect(r.errorOrNull?.message, contains('not found'));
    });

    test('a 200 with nothing parseable is reported as "no data", not "broken"',
        () async {
      // The distinction matters: the first tells the user the feature works and
      // nobody has contributed; the second sends them to check their key. Here
      // the fixture has no lookup tool, so the failure is the plain one.
      final ham = _FakeHam(tools: _scoreTool, callResult: {'unexpected': true});
      final repo = HamGradesRepository(
        client: HamMcpClient(apiKey: 'k', httpClient: ham.client),
      );
      final r = await repo.search(query: 'x');

      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
      expect(r.errorOrNull?.message, contains('没有'));
      // The one thing it must never look like is a credential problem.
      expect(r.errorOrNull?.message, isNot(contains('API')));
    });

    test('a name the service does not know says so, rather than "no data"',
        () async {
      // `search_courses` exists but returns no hits: this is "I have never heard
      // of that course", which is a different message from "nobody has
      // contributed marks for it".
      final ham = _FakeHam(tools: const [
        {
          'name': 'search_courses',
          'description': 'Look up exact course names by keyword.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'keyword': {'type': 'string'},
              'keyword_type': {'type': 'string'},
            },
            'required': ['keyword', 'keyword_type'],
          },
        },
        {
          'name': 'get_course_grade_stats',
          'description': 'Search course grade statistics list by keyword.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'keyword': {'type': 'string'},
              'type': {'type': 'string'},
              'order': {'type': 'string'},
              'cursor': {
                'type': ['null', 'string'],
              },
            },
            'required': ['keyword', 'type', 'order', 'cursor'],
          },
        },
      ], callResult: {
        'items': <Object?>[],
        'hits': <Object?>[]
      });
      final repo = HamGradesRepository(
        client: HamMcpClient(apiKey: 'k', httpClient: ham.client),
      );
      final r = await repo.search(query: '不存在的课');

      expect(r.errorOrNull?.kind, FailureKind.invalidData);
      expect(r.errorOrNull?.message, contains('没有找到'));
    });

    test('a required argument that cannot be filled is named', () async {
      // `score/stat` needs both course and instructor; a course-only query cannot
      // satisfy it. Saying which parameter is missing beats a server 400.
      final ham = _FakeHam(tools: const [
        {
          'name': 'ham_course_score_stat',
          'description':
              'Score distribution for one course and one instructor.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'course_name': {'type': 'string'},
              'instructor': {'type': 'string'},
            },
            'required': ['course_name', 'instructor'],
          },
        },
      ]);
      final repo = HamGradesRepository(
        client: HamMcpClient(apiKey: 'k', httpClient: ham.client),
      );
      final r = await repo.search(query: '数字信号处理');

      expect(r.errorOrNull?.kind, FailureKind.validation);
      expect(r.errorOrNull?.message, contains('instructor'));
      expect(ham.calls, 0,
          reason: 'nothing was sent that would fail server-side');
    });
  });

  group('the live service\'s own answer', () {
    // Captured from `get_course_grade_stats` against mcp.ham.nowcent.cn. This is
    // the shape that actually arrives — nested under `course`/`stat`, carrying a
    // `median` the proto does not have, with band colours in a sibling
    // `range_config` rather than on each band. A parser written only against the
    // documented flat shape returns nothing here.
    final payload = {
      'items': [
        {
          'course': {
            'course_idx': '数字信号处理\u001f陈小莉',
            'id': '7543cdc66331429aaf5bf0169a3d95f8',
            'instructor': '陈小莉',
            'instructor_list': ['陈小莉'],
            'name': '数字信号处理',
          },
          'stat': {
            'average': 84.84848484848484,
            'course_table_id': '7543cdc66331429aaf5bf0169a3d95f8',
            'id': 0,
            'median': 87,
            'range': [
              {'from': 0, 'to': 59, 'total': 1},
              {'from': 60, 'to': 71, 'total': 4},
              {'from': 72, 'to': 77, 'total': 4},
              {'from': 78, 'to': 84, 'total': 14},
              {'from': 85, 'to': 89, 'total': 17},
              {'from': 90, 'to': 100, 'total': 26},
            ],
            'total': 66,
          },
        },
        {
          'course': {
            'course_idx': '数字信号处理\u001f张海剑',
            'id': 'ce7c099e12984817a3609e0e193291c5',
            'instructor': '张海剑',
            'instructor_list': ['张海剑'],
            'name': '数字信号处理',
          },
          'stat': {
            'average': 90.3913043478261,
            'course_table_id': 'ce7c099e12984817a3609e0e193291c5',
            'id': 0,
            'median': 92,
            'range': [
              {'from': 0, 'to': 59, 'total': 0},
              {'from': 90, 'to': 100, 'total': 32},
            ],
            'total': 46,
          },
        },
      ],
      'range_config': [
        {'color': '#FF5722', 'from': 0, 'to': 59},
        {'color': '#FF9800', 'from': 60, 'to': 71},
        {'color': '#FFC107', 'from': 72, 'to': 77},
        {'color': '#FFEB3B', 'from': 78, 'to': 84},
        {'color': '#8BC34A', 'from': 85, 'to': 89},
        {'color': '#4CAF50', 'from': 90, 'to': 100},
      ],
    };

    test('finds both teaching teams', () {
      final scores = HamCourseScore.listFrom(payload);

      expect(scores, hasLength(2));
      expect(scores.map((s) => s.instructor), ['陈小莉', '张海剑']);
      expect(scores.every((s) => s.name == '数字信号处理'), isTrue);
    });

    test('reads the numbers out of the nested `stat`', () {
      final first = HamCourseScore.listFrom(payload).first;

      expect(first.average, closeTo(84.8484, 0.001));
      expect(first.median, 87);
      expect(first.total, 66);
      expect(first.buckets, hasLength(6));
      expect(first.buckets.last.from, 90);
      expect(first.buckets.last.total, 26);
      expect(first.courseTableId, '7543cdc66331429aaf5bf0169a3d95f8');
    });

    test('takes the band colours from the shared range_config', () {
      // The bands themselves carry no colour; without reading the sibling config
      // every bar would render in the fallback colour.
      final first = HamCourseScore.listFrom(payload).first;

      expect(first.buckets.first.color, '#FF5722');
      expect(first.buckets.last.color, '#4CAF50');
    });

    test('scales bars to the busiest band', () {
      final first = HamCourseScore.listFrom(payload).first;
      expect(first.busiestBucket, 26);
    });

    test('a course with no contributions is an empty list, not an error', () {
      // `高等数学` answers this way: the exact name is not in the table because
      // Ham stores it as 高等数学A/B/C/D…, so the caller reports "no data".
      expect(HamCourseScore.listFrom({'items': <Object?>[]}), isEmpty);
    });
  });
}
