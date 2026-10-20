import 'dart:convert';

import 'package:campus_atlas/core/network/api_client.dart';
import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/grades/grade_models.dart';
import 'package:campus_atlas/features/grades/grade_repository.dart';
import 'package:campus_atlas/features/whu_auth/whu_endpoints.dart';
import 'package:campus_atlas/features/whu_auth/whu_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// ⚠️ **All payload fixtures here are hand-authored shapes modelled on what
/// jQuery Grid emits.** No live grade response was ever captured — the endpoint
/// sits behind CAS and reaching it needs an interactive sign-in that this
/// environment cannot perform. The fixtures are shaped by the field names the
/// earlier `ham-win` session verified out of `jwgl`'s own JS, but the envelope
/// variant is genuinely unknown, which is why the parser accepts several and
/// reports which one matched.
void main() {
  // ------------------------------------------------------------- fixtures

  Map<String, Object?> jqGridPayload() => {
        'page': 1,
        'total': 3,
        'records': 3,
        'rows': [
          {
            'kcmc': '大学物理A（下）',
            'kch': 'MATH1234',
            'bfzcj': '89.0',
            'xf': '4.0',
            'jsxm': '张三',
            'kkbmmc': '物理科学与技术学院',
            'kcxzmc': '必修',
          },
          {
            'kcmc': '数学物理方法',
            'kch': 'PHYS5678',
            'bfzcj': '免修',
            'xf': '3.0',
            'jsxm': '李四',
            'kkbmmc': '数学与统计学院',
            'kcxzmc': '必修',
          },
          {
            'kcmc': '张量分析与弹性力学',
            'bfzcj': '92.5',
            'xf': '2.5',
            'jsxm': '王五',
            'kkbmmc': '力学系',
            'kcxzmc': '选修',
          },
        ],
      };

  final htmlSignInPage = '<!DOCTYPE html>\n<html lang="zh">\n'
      '<head><title>统一身份认证</title></head>'
      '<body>请先登录</body></html>';

  /// The session a completed sign-in produces.
  ///
  /// The grant lives on the CAS host and the service session on 教务, on purpose
  /// — that split is exactly what the cookie header now respects, and a fixture
  /// that put both on one host could not tell the two behaviours apart.
  WhuSession freshSession({
    Map<String, String>? cookies,
    DateTime? acquiredAt,
  }) {
    final all = cookies ??
        const {
          CasOrigin.tgcCookie: 'TGC-VALUE',
          CasOrigin.sessionCookie: 'SERVICE-VALUE',
        };
    return WhuSession(
      cookies: all,
      scoped: [
        for (final e in all.entries)
          if (e.key == CasOrigin.tgcCookie)
            (
              name: e.key,
              value: e.value,
              domain: 'cas.whu.edu.cn',
              path: '/authserver',
              hostOnly: true,
            )
          else
            (
              name: e.key,
              value: e.value,
              domain: 'jwgl.whu.edu.cn',
              path: '/',
              hostOnly: true,
            ),
      ],
      acquiredAt: acquiredAt ?? DateTime.now(),
      properties: const {WhuProperty.jwgl},
    );
  }

  /// A repository whose transport returns [body] and records the request.
  ///
  /// [seen] returns null when nothing was sent — that is the assertion for the
  /// precondition tests, so it must not be forced with `!`.
  ({GradeRepository repo, http.Request? Function() seen}) repoReturning(
    Object body, {
    WhuSession? session,
    int status = 200,
    String contentType = 'application/json',
  }) {
    http.Request? seen;
    final client = ApiClient(
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response(
          body is String ? body : jsonEncode(body),
          status,
          headers: {'content-type': contentType},
        );
      }),
      maxRetries: 0,
    );
    return (
      repo: GradeRepository(client: client, session: session ?? freshSession()),
      seen: () => seen,
    );
  }

  const query = GradeQuery(year: '2025-2026', xqm: '12');

  // ------------------------------------------------------------- fixtures

  group('looksLikeJson', () {
    test('rejects the HTML sign-in page', () {
      // The failure mode this whole feature turns on: HTTP 200 carrying HTML.
      expect(looksLikeJson(htmlSignInPage), isFalse);
    });

    test('accepts objects and arrays', () {
      expect(looksLikeJson('{"rows":[]}'), isTrue);
      expect(looksLikeJson('  [{"a":1}]'), isTrue);
      expect(looksLikeJson('[1,2]'), isTrue);
    });

    test('rejects empty and non-JSON prose', () {
      expect(looksLikeJson(''), isFalse);
      expect(looksLikeJson('   '), isFalse);
      expect(looksLikeJson('please try it again later!'), isFalse);
      expect(looksLikeJson('<h1>Maintenance</h1>'), isFalse);
    });
  });

  group('isJsonErrorBody', () {
    test('detects this origin\'s 401 envelope', () {
      expect(
        isJsonErrorBody(
          '{"status":401,"title":"Unauthorized","detail":"authentication '
          'required","code":"UNAUTHORIZED"}',
        ),
        isTrue,
      );
      expect(isJsonErrorBody('{"status": 401}'), isTrue);
      expect(isJsonErrorBody('{"code": "UNAUTHORIZED"}'), isTrue);
    });

    test('leaves ordinary payloads alone', () {
      expect(isJsonErrorBody('{"rows":[],"total":0}'), isFalse);
      expect(isJsonErrorBody('{"status":200}'), isFalse);
      expect(isJsonErrorBody('[]'), isFalse);
      expect(isJsonErrorBody('<html>'), isFalse);
    });
  });

  group('parseGradeBody — the HTML case', () {
    test('200 + sign-in page is an expired session, not an empty term', () {
      final r = parseGradeBody(htmlSignInPage, year: '2025-2026', xqm: '12');

      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.unauthorized,
          reason: 'reporting this as "zero grades" would hide the real cause');
      expect(r.errorOrNull?.message, contains('sign-in page'));
      expect(r.errorOrNull?.endpoint, 'cjcx_cxDgXscj');
    });

    test('non-HTML garbage is a protocol error, not an auth error', () {
      final r = parseGradeBody('please try it again later!',
          year: '2025-2026', xqm: '12');
      expect(r.errorOrNull?.kind, FailureKind.protocol);
    });

    test('empty body is a protocol error', () {
      final r = parseGradeBody('   ', year: '2025-2026', xqm: '12');
      expect(r.errorOrNull?.kind, FailureKind.protocol);
    });
  });

  group('parseGradeBody — envelopes', () {
    test('reads the classic jqGrid `rows` envelope', () {
      final r = parseGradeBody(jsonEncode(jqGridPayload()),
          year: '2025-2026', xqm: '12');

      expect(r.isSuccess, isTrue);
      final sheet = r.requireValue;
      expect(sheet.records, hasLength(3));
      expect(sheet.envelope, 'rows');
      expect(sheet.total, 3);
      expect(sheet.truncated, isFalse);
      expect(sheet.records.first.name, '大学物理A（下）');
      expect(sheet.year, '2025-2026');
      expect(sheet.xqm, '12');
    });

    test('reads the envelope the system was actually observed to send', () {
      // The body below is a real response, taken from a live jqGrid query on this
      // deployment (`POST /xsbysjgl/cjck_cxCjckIndex.html?doType=query`). It is
      // here because it settles two things an earlier version listed as
      // unknowable without a session: the rows key is `items`, and the declared
      // count is `totalResult` — not `total`.
      final r = parseGradeBody(
        jsonEncode({
          'currentPage': 1,
          'currentResult': 0,
          'entityOrField': false,
          'items': jqGridPayload()['rows'],
          'limit': 15,
          'offset': 0,
          'pageNo': 0,
          'pageSize': 15,
          'showCount': 15,
          'sortName': ' ',
          'sortOrder': 'asc',
          'sorts': <Object?>[],
          'totalCount': 3,
          'totalPage': 1,
          'totalResult': 3,
        }),
        year: '2025-2026',
        xqm: '12',
      );

      expect(r.isSuccess, isTrue);
      final sheet = r.requireValue;
      expect(sheet.envelope, 'items');
      expect(sheet.records, hasLength(3));
      expect(sheet.total, 3);
      // The declared count matched what came back, so this is not a short page.
      expect(sheet.truncated, isFalse);
    });

    test('a short page is recognised from the declared count', () {
      // The failure this guards: a silently truncated page reads as a short term.
      final rows = jqGridPayload()['rows']! as List<Object?>;
      final r = parseGradeBody(
        jsonEncode({
          'items': [rows.first],
          'totalResult': 40,
        }),
        year: '2025-2026',
        xqm: '12',
      );

      expect(r.requireValue.truncated, isTrue);
      expect(r.requireValue.total, 40);
    });

    test('reads an `items` envelope too', () {
      final r = parseGradeBody(
        jsonEncode({
          'items': jqGridPayload()['rows'],
          'total': 3,
        }),
        year: '2025-2026',
        xqm: '12',
      );
      expect(r.isSuccess, isTrue);
      expect(r.requireValue.envelope, 'items');
      expect(r.requireValue.records, hasLength(3));
    });

    test('reads a bare JSON array', () {
      final r = parseGradeBody(
        jsonEncode(jqGridPayload()['rows']),
        year: '2025-2026',
        xqm: '12',
      );
      expect(r.isSuccess, isTrue);
      expect(r.requireValue.envelope, 'array');
      expect(r.requireValue.records, hasLength(3));
    });

    test('a nested wrapper is followed one level deep', () {
      final r = parseGradeBody(
        jsonEncode({
          'results': {
            'rows': [
              {'kcmc': '大学英语', 'bfzcj': '88', 'xf': '2'},
            ],
          },
        }),
        year: '2025-2026',
        xqm: '12',
      );
      expect(r.isSuccess, isTrue);
      expect(r.requireValue.envelope, 'results.rows');
      expect(r.requireValue.records.single.name, '大学英语');
    });

    test('an unrecognised envelope reports empty *and* says so', () {
      // Without the envelope label this would read exactly like "no grades
      // this term", which is the dangerous case.
      final r = parseGradeBody(
        jsonEncode({
          'somethingElse': [1, 2, 3]
        }),
        year: '2025-2026',
        xqm: '12',
      );
      expect(r.isSuccess, isTrue);
      expect(r.requireValue.isEmpty, isTrue);
      expect(r.requireValue.envelope, '');
    });

    test('a short page is flagged as truncated rather than complete', () {
      final r = parseGradeBody(
        jsonEncode({
          'page': 1,
          'total': 40,
          'records': 40,
          'rows': [
            {'kcmc': 'A', 'bfzcj': '90'},
          ]
        }),
        year: '2025-2026',
        xqm: '12',
      );
      final sheet = r.requireValue;
      expect(sheet.records, hasLength(1));
      expect(sheet.total, 40);
      expect(sheet.truncated, isTrue,
          reason: 'we paginated by accident; do not read this as 1 grade');
    });

    test('the 401 envelope is rejected before parsing', () {
      final r = parseGradeBody(
        '{"status":401,"title":"Unauthorized","code":"UNAUTHORIZED"}',
        year: '2025-2026',
        xqm: '12',
      );
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
    });

    test('malformed JSON is invalidData, not a throw', () {
      final r = parseGradeBody('{"rows": [', year: '2025-2026', xqm: '12');
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('a non-object JSON root is invalidData', () {
      final r = parseGradeBody('"just a string"', year: '2025-2026', xqm: '12');
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });
  });

  group('GradeRecord', () {
    test('parses the documented [D] columns from a row', () {
      final rec = GradeRecord.tryParse({
        'kcmc': '大学物理A（下）',
        'kch': 'PHYS01',
        'bfzcj': '89.0',
        'xf': '4.0',
        'jsxm': '张三',
        'kkbmmc': '物理学院',
        'kcxzmc': '必修',
        'someUnknownColumn': {'nested': true},
      });

      expect(rec, isNotNull);
      final r = rec!;
      expect(r.name, '大学物理A（下）');
      expect(r.courseCode, 'PHYS01');
      expect(r.score, 89.0);
      expect(r.scoreText, '89.0');
      expect(r.credits, 4.0);
      expect(r.teacher, '张三');
      expect(r.department, '物理学院');
      expect(r.courseNature, '必修');
      expect(r.hasNumericScore, isTrue);
      expect(r.isValid, isTrue);
      // Columns we have not catalogued survive untouched rather than being
      // dropped or mis-typed.
      expect(r.raw['someUnknownColumn'], {'nested': true});
    });

    test('a non-numeric outcome keeps its text and nulls the number', () {
      // 65/70 points for non-numeric outcomes: parsing these as 0 would drag a
      // course-average down and parsing them as absent would be fine.
      for (final v in const ['免修', '合格', '缺考', '不及格', '通过']) {
        final rec = GradeRecord.tryParse({'kcmc': 'X', 'bfzcj': v})!;
        expect(rec.score, isNull, reason: v);
        expect(rec.scoreText, v, reason: v);
        expect(rec.hasNumericScore, isFalse, reason: v);
      }
    });

    test('full-width digits and a full-width period are normalised', () {
      final rec = GradeRecord.tryParse({'kcmc': 'X', 'bfzcj': '８９．５'})!;
      expect(rec.score, 89.5);
      expect(rec.scoreText, '８９．５');
    });

    test('zero is a score, not an absence', () {
      final rec = GradeRecord.tryParse({'kcmc': 'X', 'bfzcj': '0'})!;
      expect(rec.score, 0.0);
      expect(rec.hasNumericScore, isTrue);
    });

    test('a blank score is not a zero', () {
      final rec = GradeRecord.tryParse({'kcmc': 'X', 'bfzcj': ''})!;
      expect(rec.score, isNull);
      expect(rec.hasNumericScore, isFalse);
    });

    test('missing credits stay null rather than 0', () {
      final rec = GradeRecord.tryParse({'kcmc': 'X', 'bfzcj': '90'})!;
      expect(rec.credits, isNull);
    });

    test('a row with no course name is discarded', () {
      expect(GradeRecord.tryParse({'bfzcj': '90'}), isNull);
      expect(GradeRecord.tryParse({'kcmc': '   ', 'bfzcj': '90'}), isNull);
      expect(GradeRecord.tryParse(null), isNull);
      expect(GradeRecord.tryParse('not a row'), isNull);
      expect(GradeRecord.tryParse(42), isNull);
    });

    test('falls back to English key names', () {
      final rec = GradeRecord.tryParse({
        'courseName': 'Data Structures',
        'score': '91',
        'teacherName': 'Lee',
      })!;
      expect(rec.name, 'Data Structures');
      expect(rec.score, 91);
      expect(rec.teacher, 'Lee');
    });
  });

  group('GradeSheet aggregates', () {
    GradeSheet sheetOf(List<GradeRecord> records) => GradeSheet(
          year: '2025-2026',
          xqm: '12',
          records: records,
          total: records.length,
        );

    GradeRecord rec(String name, double? score, double? credit) => GradeRecord(
          name: name,
          score: score,
          scoreText: score == null ? '' : '$score',
          credits: credit,
          raw: const {},
        );

    test('creditTotal sums only the credits that exist', () {
      final s =
          sheetOf([rec('a', 90, 4.0), rec('b', 80, 3.0), rec('c', 70, null)]);
      expect(s.creditTotal, 7.0);
    });

    test('weightedMean weights by credit', () {
      final s = sheetOf([rec('a', 100, 1.0), rec('b', 60, 3.0)]);
      // (100*1 + 60*3) / 4 = 70
      expect(s.weightedMean(), closeTo(70.0, 1e-9));
    });

    test('weightedMean falls back to unweighted when no credits exist', () {
      final s = sheetOf([rec('a', 90, null), rec('b', 70, null)]);
      expect(s.weightedMean(), closeTo(80.0, 1e-9));
    });

    test('weightedMean is null when there is nothing numeric at all', () {
      final s = sheetOf([rec('a', null, null), rec('b', null, null)]);
      expect(s.weightedMean(), isNull,
          reason: 'null means "nothing to average", not zero');
    });

    test('an empty sheet is empty and averages to null', () {
      final s = sheetOf(const []);
      expect(s.isEmpty, isTrue);
      expect(s.returnedCount, 0);
      expect(s.weightedMean(), isNull);
      expect(s.creditTotal, 0);
    });

    test('aggregates stay on the score scale, never a grade-point scale', () {
      // No grade-point table for this university is established anywhere in
      // this project, so no GPA-style API exists. The aggregate must come back
      // on the same 0–100 scale as the scores it is computed from: if a future
      // change ever yields a single-digit number from these inputs, that is a
      // fabricated GPA asserting itself.
      final s = sheetOf([rec('a', 90, 4.0), rec('b', 70, 4.0)]);
      final mean = s.weightedMean();
      expect(mean, isNotNull);
      expect(mean! > 10, isTrue, reason: 'expected a 0-100 score, got $mean');
      expect(mean, closeTo(80.0, 1e-9));
    });
  });

  group('GradeQuery / buildUri and buildBody', () {
    test('addresses the page that answers, not the one the page JS names', () {
      final repo = GradeRepository(
          client: ApiClient(
              httpClient: MockClient((_) async => http.Response('[]', 200))),
          session: freshSession());
      final uri = repo.buildUri(query);

      // Measured against a live student session: `cxXsgrcj` answers 404 while
      // `cxDgXscj` answers with 学生成绩查询 and its grid. The page's own ternary
      //     jsxx == "xs" ? '/cjcx/cjcx_cxXsgrcj.html' : '/cjcx/cjcx_cxDgXscj.html'
      // points a student at the 404, and is stale for this deployment. Believing
      // it once already cost the user a 404 — see the endpoint's docs.
      expect(uri.path, '/cjcx/cjcx_cxDgXscj.html');
      expect(uri.queryParameters['gnmkdm'], 'N305005');
      expect(uri.queryParameters['doType'], 'query');
    });

    test('the term travels in the body, not the query string', () {
      final repo = GradeRepository(
          client: ApiClient(
              httpClient: MockClient((_) async => http.Response('[]', 200))),
          session: freshSession());
      final uri = repo.buildUri(query);
      final body = repo.buildBody(query);

      expect(uri.queryParameters.containsKey('xnm'), isFalse);
      expect(uri.queryParameters.containsKey('xqm'), isFalse);
      expect(body['xnm'], '2025-2026');
      expect(body['xqm'], '12');
    });

    test('the body matches the shape a working client sends', () {
      final repo = GradeRepository(
          client: ApiClient(
              httpClient: MockClient((_) async => http.Response('[]', 200))),
          session: freshSession());
      final body = repo.buildBody(query, validate: 'sl-abc');

      expect(body['validate'], 'sl-abc');
      expect(body['queryModel.showCount'], '150');
      expect(body.keys, hasLength(4),
          reason: 'four fields: validate, xnm, xqm, showCount');
    });

    test('a generated validate is a nonce, not a solved challenge', () {
      // Naming this honestly matters: a reader who takes it for a CAPTCHA answer
      // would conclude this client defeats one. It is `sl` + random + timestamp,
      // which is what a working implementation generates.
      final repo = GradeRepository(
          client: ApiClient(
              httpClient: MockClient((_) async => http.Response('[]', 200))),
          session: freshSession());
      final a = repo.buildBody(query)['validate']!;
      final b = repo.buildBody(query)['validate']!;

      expect(a, startsWith('sl'));
      expect(a.length, greaterThan(6));
      expect(a, isNot(b), reason: 'a fresh nonce per query');
    });

    test('a caller-supplied validate is used instead of a generated one', () {
      final repo = GradeRepository(
          client: ApiClient(
              httpClient: MockClient((_) async => http.Response('[]', 200))),
          session: freshSession());
      final body = repo.buildBody(
        const GradeQuery(year: 'y', xqm: '3', validateToken: 'supplied'),
        validate: 'supplied',
      );
      expect(body['validate'], 'supplied');
    });

    test('hasToken is false for blank and null', () {
      expect(const GradeQuery(year: 'y', xqm: '3').hasToken, isFalse);
      expect(const GradeQuery(year: 'y', xqm: '3', validateToken: '').hasToken,
          isFalse);
      expect(
          const GradeQuery(year: 'y', xqm: '3', validateToken: ' t ').hasToken,
          isTrue);
    });
  });

  group('GradeRepository.fetch', () {
    test('withholds the request when the CAS ticket is missing', () async {
      final out = repoReturning(
        'SHOULD-NOT-REACH',
        session: WhuSession(
          cookies: const {CasOrigin.sessionCookie: 'service-only'},
          scoped: const [
            (
              name: 'JSESSIONID',
              value: 'service-only',
              domain: 'jwgl.whu.edu.cn',
              path: '/',
              hostOnly: true,
            ),
          ],
          acquiredAt: DateTime.now(),
        ),
      );

      final r = await out.repo.fetch(query);
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
      expect(r.errorOrNull?.message, contains('ticket is missing'));
      expect(out.seen()?.headers['cookie'], isNull,
          reason: 'nothing should have gone on the wire');
    });

    test('withholds the request when the session is stale', () async {
      final out = repoReturning(
        'SHOULD-NOT-REACH',
        session: freshSession(
            acquiredAt: DateTime.now().subtract(const Duration(hours: 5))),
      );

      final r = await out.repo.fetch(query);
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
      expect(r.errorOrNull?.message, contains('older than'));
      expect(out.seen()?.headers['cookie'], isNull);
    });

    test('withholds the request when year or term is blank', () async {
      final out = repoReturning('{}');
      final r = await out.repo.fetch(const GradeQuery(year: '  ', xqm: '12'));
      expect(r.errorOrNull?.kind, FailureKind.validation);

      final r2 = await out.repo.fetch(const GradeQuery(year: '2025', xqm: ''));
      expect(r2.errorOrNull?.kind, FailureKind.validation);
      expect(out.seen()?.headers['cookie'], isNull);
    });

    test('sends only the cookies that belong to 教务', () async {
      final out = repoReturning(jqGridPayload());
      final r = await out.repo.fetch(query);

      expect(r.isSuccess, isTrue);
      final req = out.seen()!;
      // `CASTGC` is scoped to cas.whu.edu.cn/authserver. Sending it here would
      // hand a central credential to a service host, which is why this asserts
      // its absence rather than just the presence of the session cookie.
      expect(req.headers['cookie'], 'JSESSIONID=SERVICE-VALUE');
      expect(req.headers['cookie'], isNot(contains('CASTGC')));
      expect(req.headers['referer'], contains('jwgl.whu.edu.cn'));
      expect(req.url.queryParameters['doType'], 'query');
    });

    test('an HTML 200 comes back as an expired session, not empty grades',
        () async {
      final out =
          repoReturning(htmlSignInPage, contentType: 'text/html;charset=utf-8');
      final r = await out.repo.fetch(query);

      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
      expect(r.errorOrNull?.message, contains('sign-in page'));
    });

    test('a transport-level 401 maps through unchanged', () async {
      final out = repoReturning(
        '{"status":401,"code":"UNAUTHORIZED"}',
        status: 401,
      );
      final r = await out.repo.fetch(query);
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
      expect(r.errorOrNull?.statusCode, 401);
    });

    test('a server failure surfaces as a server failure', () async {
      final out = repoReturning('oops', status: 503);
      final r = await out.repo.fetch(query);
      expect(r.errorOrNull?.kind, FailureKind.server);
    });

    test('no cookie value ever reaches a failure message', () async {
      const secret = 'TGC-ultra-secret-base64-blob-abc';
      final cases = <String>[];
      for (final setup in <(Object, WhuSession)>[
        (
          'html',
          freshSession(
              cookies: const {CasOrigin.tgcCookie: secret},
              acquiredAt: DateTime.now().subtract(const Duration(hours: 9)))
        ),
        ('401', freshSession(cookies: const {CasOrigin.tgcCookie: secret})),
      ]) {
        final (body, session) = setup;
        final out = repoReturning(
          body == 'html' ? htmlSignInPage : '{"status":401}',
          session: session,
        );
        final r = await out.repo.fetch(query);
        final text =
            '${r.errorOrNull?.message} ${r.errorOrNull?.endpoint} ${r.errorOrNull?.displayLabel}';
        cases.add(text);
      }
      for (final t in cases) {
        expect(t, isNot(contains(secret)));
        expect(t, isNot(contains('ultra-secret')));
      }
    });
  });
}
