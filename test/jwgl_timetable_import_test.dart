import 'dart:convert';

import 'package:campus_atlas/core/network/api_client.dart';
import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/timetable/import/jwgl_timetable_parser.dart';
import 'package:campus_atlas/features/timetable/import/jwgl_timetable_repository.dart';
import 'package:campus_atlas/features/whu_auth/cas_navigation.dart';
import 'package:campus_atlas/features/whu_auth/whu_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A live-shaped N2151 answer. The field names are 正方's published convention
/// (`kcmc`, `xqj`, `jcs`, `zcd`, `xm`, `cdmc`, `qsjsj`, `jssj`); the rows cover
/// every form the parser has to understand, including the two that real data
/// always contains: split week ranges for one course, and a row that cannot be
/// placed.
const _payload = {
  'kbList': [
    {
      'kcmc': '高等数学A1',
      'xqj': '1',
      'jcs': '1-2节',
      'zcd': '1-16周',
      'xm': '张三',
      'cdmc': '教五-101',
      'qsjsj': '08:00',
      'jssj': '09:40',
    },
    {
      'kcmc': '大学物理',
      'xqj': '3',
      'jcs': '3-4节',
      'zcd': '1-8周,10-16周',
      'xm': '李四',
      'cdmc': '教一-201',
      'qsjsj': '10:00:00',
      'jssj': '11:40:00',
    },
    {
      'kcmc': '体育',
      'xqj': '5',
      'jcs': '5-6节',
      'zcd': '1-15周(单)',
      'xm': '王五',
      'cdmc': '操场',
    },
    {
      'kcmc': '大学英语',
      'xqj': '2',
      'jcs': '1-2节',
      'zcd': '1-16周(双)',
      'xm': '赵六',
      'cdmc': '外语楼',
    },
    {
      'kcmc': '数据结构',
      'xqj': '4',
      'jcs': '7-8节',
      'zcd': '1-8周',
      'xm': '钱七',
      'cdmc': '计算机楼',
    },
    {
      'kcmc': '数据结构',
      'xqj': '4',
      'jcs': '7-8节',
      'zcd': '9-16周',
      'xm': '钱七',
      'cdmc': '计算机楼',
    },
    // Skipped rows: bad weekday, no weeks, no name.
    {'kcmc': '坏行', 'xqj': '9', 'jcs': '1-2节', 'zcd': '1-16周'},
    {'kcmc': '没有周次', 'xqj': '1', 'jcs': '1-2节', 'zcd': ''},
    {'xqj': '1', 'jcs': '1-2节', 'zcd': '1-16周'},
  ],
};

CookieData cookie(String name, String value,
        {String domain = 'jwgl.whu.edu.cn'}) =>
    (
      name: name,
      value: value,
      domain: domain,
      path: '/',
      hostOnly: true,
    );

WhuSession session() => WhuSession(
      cookies: {
        'CASTGC': 'TGC-value',
        'JSESSIONID': 'SESSION-value',
      },
      scoped: [
        cookie('CASTGC', 'TGC-value', domain: 'cas.whu.edu.cn'),
        cookie('JSESSIONID', 'SESSION-value'),
      ],
      acquiredAt: DateTime.now(),
      properties: const {WhuProperty.jwgl},
    );

void main() {
  group('parseJwglTimetable', () {
    final parsed = parseJwglTimetable(_payload).requireValue;

    test('reads every placeable row and counts the rest', () {
      expect(parsed.courses, hasLength(5));
      expect(parsed.skipped, 3);
      expect(parsed.problems, isNotEmpty);
    });

    test('orders by weekday and start period', () {
      expect(
        parsed.courses.map((c) => c.name),
        ['高等数学A1', '大学英语', '大学物理', '数据结构', '体育'],
      );
    });

    test('keeps the times, normalising seconds away', () {
      final physics = parsed.courses.firstWhere((c) => c.name == '大学物理');
      expect(physics.startTime, '10:00');
      expect(physics.endTime, '11:40');
      final maths = parsed.courses.firstWhere((c) => c.name == '高等数学A1');
      expect(maths.startTime, '08:00');
    });

    test('expands odd and even week specifications', () {
      final sport = parsed.courses.firstWhere((c) => c.name == '体育');
      expect(sport.weeks, {for (var w = 1; w <= 15; w += 2) w});
      final english = parsed.courses.firstWhere((c) => c.name == '大学英语');
      expect(english.weeks, {for (var w = 2; w <= 16; w += 2) w});
    });

    test('reads a comma-separated week range with a gap', () {
      final physics = parsed.courses.firstWhere((c) => c.name == '大学物理');
      expect(physics.weeks, {
        for (var w = 1; w <= 8; w++) w,
        for (var w = 10; w <= 16; w++) w,
      });
      expect(physics.weeks.contains(9), isFalse);
    });

    test('merges two week ranges of the same slot into one course', () {
      final structures = parsed.courses.where((c) => c.name == '数据结构').toList();
      expect(structures, hasLength(1));
      expect(structures.single.weeks, {for (var w = 1; w <= 16; w++) w});
    });

    test('ids are stable across parses', () {
      final again = parseJwglTimetable(_payload).requireValue;
      expect(
        again.courses.map((c) => c.id).toList(),
        parsed.courses.map((c) => c.id).toList(),
      );
    });

    test('accepts a JSON string as well as a decoded map', () {
      final fromString = parseJwglTimetable(jsonEncode(_payload));
      expect(fromString.requireValue.courses, hasLength(5));
    });

    test('a payload without kbList is a typed failure', () {
      final result = parseJwglTimetable(const {'something': 'else'});
      expect(result.isFailure, isTrue);
      expect(result.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('a non-object payload is a typed failure', () {
      expect(parseJwglTimetable(const [1, 2, 3]).isFailure, isTrue);
      expect(parseJwglTimetable('not json').isFailure, isTrue);
    });
  });

  group('field parsers', () {
    test('weekday accepts digits and Chinese names', () {
      expect(parseJwglWeekday('3'), 3);
      expect(parseJwglWeekday(5), 5);
      expect(parseJwglWeekday('星期一'), 1);
      expect(parseJwglWeekday('周日'), 7);
      expect(parseJwglWeekday('星期日'), 7);
      expect(parseJwglWeekday('8'), isNull);
      expect(parseJwglWeekday(''), isNull);
    });

    test('periods read a range or a single period', () {
      expect(parseJwglPeriods('1-2节'), (start: 1, count: 2));
      expect(parseJwglPeriods('第3节'), (start: 3, count: 1));
      expect(parseJwglPeriods('7-8'), (start: 7, count: 2));
      expect(parseJwglPeriods(''), isNull);
      expect(parseJwglPeriods('节'), isNull);
    });

    test('weeks read every documented form', () {
      expect(parseJwglWeeks('1-16周'), {for (var w = 1; w <= 16; w++) w});
      expect(parseJwglWeeks('第1-4周'), {1, 2, 3, 4});
      expect(parseJwglWeeks('1-15周(单)'), {for (var w = 1; w <= 15; w += 2) w});
      expect(parseJwglWeeks('1-16周(双)'), {for (var w = 2; w <= 16; w += 2) w});
      expect(parseJwglWeeks('1-16周(单双)'), {for (var w = 1; w <= 16; w++) w});
      expect(parseJwglWeeks('3,5,7'), {3, 5, 7});
      expect(parseJwglWeeks('1-4周,6周'), {1, 2, 3, 4, 6});
      expect(parseJwglWeeks(''), isNull);
      expect(parseJwglWeeks('abc'), isNull);
    });
  });

  group('JwglTimetableRepository', () {
    test('posts the documented form and parses the answer', () async {
      late http.Request captured;
      final client = ApiClient(
        maxRetries: 0,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response.bytes(
            utf8.encode(jsonEncode(_payload)),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final result = await JwglTimetableRepository(
        client: client,
        session: session(),
      ).fetch(year: '2026', term: '3');

      expect(result.isSuccess, isTrue, reason: result.errorOrNull?.message);
      expect(result.requireValue.courses, hasLength(5));
      expect(captured.method, 'POST');
      expect(captured.url.path, '/kbcx/xskbcx_cxXsKb.html');
      expect(captured.url.queryParameters['gnmkdm'], 'N2151');
      expect(captured.bodyFields, {'xnm': '2026', 'xqm': '3'});
      expect(captured.headers['cookie'], contains('JSESSIONID=SESSION-value'));
      expect(captured.headers['cookie'], isNot(contains('CASTGC')));
    });

    test('no session is an unauthorized failure, not a crash', () async {
      final client = ApiClient(httpClient: MockClient((_) async {
        fail('no request should be sent without a session');
      }));

      final result = await JwglTimetableRepository(
        client: client,
        session: null,
      ).fetch(year: '2026', term: '3');

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull?.kind, FailureKind.unauthorized);
    });

    test('a sign-in page is reported as an expired session', () async {
      final client = ApiClient(
        maxRetries: 0,
        httpClient: MockClient((_) async => http.Response(
              '<html><body>authserver login</body></html>',
              200,
              headers: {'content-type': 'text/html'},
            )),
      );

      final result = await JwglTimetableRepository(
        client: client,
        session: session(),
      ).fetch(year: '2026', term: '3');

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull?.kind, FailureKind.unauthorized);
    });

    test('an empty year is refused before any request', () async {
      final client = ApiClient(httpClient: MockClient((_) async {
        fail('no request should be sent with an empty year');
      }));

      final result = await JwglTimetableRepository(
        client: client,
        session: session(),
      ).fetch(year: '  ', term: '3');

      expect(result.errorOrNull?.kind, FailureKind.validation);
    });

    test('a stalled session is refused as stale', () async {
      final client = ApiClient(httpClient: MockClient((_) async {
        fail('no request should be sent with a stale session');
      }));
      final stale = WhuSession(
        cookies: const {'CASTGC': 'x'},
        scoped: [
          (
            name: 'CASTGC',
            value: 'x',
            domain: 'cas.whu.edu.cn',
            path: '/authserver',
            hostOnly: true,
          ),
        ],
        acquiredAt: DateTime.now().subtract(const Duration(hours: 3)),
      );

      final result = await JwglTimetableRepository(
        client: client,
        session: stale,
      ).fetch(year: '2026', term: '3');

      expect(result.errorOrNull?.kind, FailureKind.unauthorized);
    });
  });
}
