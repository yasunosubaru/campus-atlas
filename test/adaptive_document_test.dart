import 'package:campus_atlas/features/teaching_eval/adaptive_document.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the schema-agnostic response reader.
///
/// Because `ugsqs` exposes no credential-free contract, these fixtures are
/// deliberately *varied* rather than representative: the reader's whole job is
/// to cope with shapes nobody has catalogued yet.
void main() {
  group('parse — kind detection', () {
    test('an empty body is empty', () {
      for (final b in const ['', '   ', '\n\t ']) {
        final d = AdaptiveDocument.parse(b);
        expect(d.kind, DocKind.empty, reason: '[$b]');
        expect(d.hasData, isFalse);
        expect(d.isVacuous, isTrue);
      }
    });

    test('objects and arrays are json', () {
      expect(AdaptiveDocument.parse('{"a":1}').kind, DocKind.json);
      expect(AdaptiveDocument.parse('[1,2]').kind, DocKind.json);
      expect(AdaptiveDocument.parse('  {"a":1}  ').kind, DocKind.json,
          reason: 'leading whitespace must not change the verdict');
    });

    test('a truncated body is malformed, not text', () {
      // Same symptom, different meaning: this one implies a successful request
      // that broke in transfer, which is worth distinguishing in a log.
      expect(AdaptiveDocument.parse('{"a": [1,2').kind, DocKind.malformed);
      expect(AdaptiveDocument.parse('{"a": [1,2').hasData, isFalse);
    });

    test('html is html', () {
      expect(AdaptiveDocument.parse('<!DOCTYPE html><html></html>').kind,
          DocKind.html);
      expect(AdaptiveDocument.parse('<div>hi</div>').kind, DocKind.html);
    });

    test('prose is text', () {
      expect(AdaptiveDocument.parse('please try it again later!').kind,
          DocKind.text);
      expect(AdaptiveDocument.parse('OK').kind, DocKind.text);
    });
  });

  group('sign-in page detection', () {
    test('a CAS sign-in page is recognised as such', () {
      const body = '<!DOCTYPE html>\n<html lang="zh">\n'
          '<head><title>武汉大学统一身份认证</title></head>\n'
          '<body><form action="https://cas.whu.edu.cn/authserver/login">'
          '<input type="password" name="password"></form></body></html>';

      final d = AdaptiveDocument.parse(body);
      expect(d.kind, DocKind.html);
      expect(d.isSignInPage, isTrue,
          reason: 'read as an empty document this would look like a working '
              'code path returning no data');
      expect(d.htmlTitle, '武汉大学统一身份认证');
      expect(d.hasData, isFalse);
    });

    test('an unrelated page is not mistaken for a sign-in wall', () {
      const body = '<html><head><title>图书馆座位预约</title></head>'
          '<body>请选择区域</body></html>';
      expect(AdaptiveDocument.parse(body).isSignInPage, isFalse);
    });

    test('a page with the word 登录 but no title is still caught', () {
      expect(
        AdaptiveDocument.parse('<html><body>请重新登录</body></html>').isSignInPage,
        isTrue,
      );
    });
  });

  group('root structure', () {
    test('kinds are reported from runtime types', () {
      final d = AdaptiveDocument.parse(
          '{"s":"text","n":42,"f":1.5,"b":true,"z":null,"o":{"k":1},"a":[1,2]}');
      final obj = d.root!;
      expect(obj.kind, NodeKind.object);
      expect(obj.object!['s']!.kind, NodeKind.string);
      expect(obj.object!['n']!.kind, NodeKind.number);
      expect(obj.object!['f']!.kind, NodeKind.number);
      expect(obj.object!['b']!.kind, NodeKind.boolean);
      expect(obj.object!['z']!.kind, NodeKind.nullValue);
      expect(obj.object!['o']!.kind, NodeKind.object);
      expect(obj.object!['a']!.kind, NodeKind.array);
    });

    test('numbers keep their literal form', () {
      final o = AdaptiveDocument.parse('{"a":100,"b":1.5,"c":-7}').root!;
      expect(o.object!['a']!.scalar, '100');
      expect(o.object!['b']!.scalar, '1.5');
      expect(o.object!['c']!.scalar, '-7');
    });

    test('unicode field names survive', () {
      final o = AdaptiveDocument.parse('{"课程名":"高等数学","评分":95}').root!;
      expect(o.object!['课程名']!.scalar, '高等数学');
      expect(o.object!['评分']!.display, '95');
    });

    test('containers describe themselves instead of dumping their subtree', () {
      final o = AdaptiveDocument.parse('{"a":[1,2,3],"b":{"x":1}}').root!;
      expect(o.object!['a']!.display, '[3]');
      expect(o.object!['b']!.display, '{1}');
      expect(o.object!['a']!.isContainer, isTrue);
      expect(o.object!['a']!.scalar, isNull);
    });

    test('a long preview is truncated', () {
      final long = '{${List.generate(500, (i) => '"f$i":$i').join(',')}}';
      final d = AdaptiveDocument.parse(long);
      expect(d.preview.length, 200);
      expect(d.hasData, isTrue, reason: 'truncation is display-only');
    });
  });

  group('at() path lookup', () {
    final doc = AdaptiveDocument.parse('''
      {
        "results": [
          {"title": "高等数学", "score": 95, "nested": {"deep": "yes"}},
          {"title": "大学物理", "score": 88}
        ],
        "meta": {"count": 2}
      }
    ''');

    test('reads a nested object', () {
      final found = doc.at('meta.count');
      expect(found, hasLength(1));
      expect(found.single.scalar, '2');
      expect(found.single.kind, NodeKind.number);
    });

    test('reads an array element by index', () {
      expect(doc.at('results.1.title').single.scalar, '大学物理');
      expect(doc.at('results.0.nested.deep').single.scalar, 'yes');
    });

    test('an empty path is the root', () {
      expect(doc.at('').single.kind, NodeKind.object);
    });

    test('a missing path is an empty list, not a throw', () {
      expect(doc.at('results.9.title'), isEmpty);
      expect(doc.at('nope.deeper'), isEmpty);
      expect(doc.at('results.0.missing'), isEmpty);
    });

    test('a non-numeric index into an array yields nothing', () {
      expect(doc.at('results.first'), isEmpty);
      expect(doc.at('meta.0'), isEmpty);
    });

    test('negative and blank segments are rejected', () {
      expect(doc.at('results.-1'), isEmpty);
      expect(doc.at('results..title'), isEmpty,
          reason: 'empty segments are skipped rather than resolved wrongly');
    });

    test('looking into a scalar yields nothing', () {
      expect(doc.at('meta.count.anything'), isEmpty);
    });

    test('an unparsed document yields nothing', () {
      expect(AdaptiveDocument.parse('<html></html>').at('a.b'), isEmpty);
      expect(AdaptiveDocument.parse('').at('a'), isEmpty);
    });
  });

  group('vacuous states', () {
    test('a json root that is an empty array is vacuous', () {
      expect(AdaptiveDocument.parse('[]').isVacuous, isTrue);
      expect(AdaptiveDocument.parse('{"rows":[]}').isVacuous, isFalse,
          reason: 'the envelope is not itself empty');
    });

    test('an empty response is vacuous', () {
      expect(AdaptiveDocument.parse('  ').isVacuous, isTrue);
    });

    test('non-empty json is not vacuous', () {
      expect(AdaptiveDocument.parse('[1]').isVacuous, isFalse);
      expect(AdaptiveDocument.parse('{"a":1}').isVacuous, isFalse);
    });
  });

  group('candidateTables', () {
    test('finds a uniform array of objects', () {
      final d = AdaptiveDocument.parse('''
        {
          "meta": {"x": 1},
          "results": [
            {"name": "A", "score": 1},
            {"name": "B", "score": 2}
          ]
        }
      ''');

      final tables = d.candidateTables();
      expect(tables, hasLength(1));
      final t = tables.single;
      expect(t.path, 'results');
      expect(t.columns, ['name', 'score']);
      expect(t.rows, hasLength(2));

      expect(t.render(), [
        ['A', '1'],
        ['B', '2'],
      ]);
    });

    test('ignores an array whose objects do not share a key set', () {
      // The column set is unknown, so a ragged array cannot honestly be
      // rendered as a table — pretending otherwise would invent alignment.
      final d = AdaptiveDocument.parse('[{"a":1},{"a":2,"b":3}]');
      expect(d.candidateTables(), isEmpty);
    });

    test('respects minColumns', () {
      final d = AdaptiveDocument.parse('[{"a":1},{"a":2}]');
      expect(d.candidateTables(minColumns: 2), isEmpty);
      expect(d.candidateTables(minColumns: 1), hasLength(1));
    });

    test('finds nested candidate tables', () {
      // Two columns so it clears the default minColumns — a single-column
      // array is rejected by design, which is what these fixtures tripped over.
      final d = AdaptiveDocument.parse('{"outer":[{"inner":[{"k":1,"j":2}]}]}');
      final tables = d.candidateTables();
      expect(tables.map((t) => t.path), contains('outer.0.inner'));
    });

    test('skips arrays of scalars', () {
      expect(
        AdaptiveDocument.parse('{"a":[1,2,3]}').candidateTables(),
        isEmpty,
      );
    });

    test('the root array itself is a candidate with an empty path', () {
      // Two columns: one would be rejected by the default minColumns, so the
      // fixture has to be wide enough for the assertion to mean anything.
      final d = AdaptiveDocument.parse('[{"k":"v","n":1},{"k":"w","n":2}]');
      final t = d.candidateTables().single;
      expect(t.path, '');
      expect(t.label, 'root');
      expect(t.columns, ['k', 'n']);
      expect(t.render(), [
        ['v', '1'],
        ['w', '2'],
      ]);
    });

    test('a present-but-null cell renders as the literal null', () {
      // A ragged array is rejected up front, so the only way a cell can be
      // absent here is a field that is genuinely present with a null value —
      // which must stay visibly null rather than looking like blank data.
      final d = AdaptiveDocument.parse('[{"k":null,"j":1},{"k":null,"j":2}]');
      final t = d.candidateTables().single;
      expect(t.render()[0][0], 'null');
    });
  });

  group('describe', () {
    test('never claims field semantics', () {
      // The reader must be able to say *what* arrived while admitting it does
      // not know *what it means* — no domain words appear in any verdict.
      const cases = {
        '': 'empty response',
        '[1,2,3]': 'json 3 items',
        '{}': 'json 0 fields',
        '<html></html>': 'html page',
        'plain words': 'plain text',
        '{"a":': 'truncated or corrupt json',
      };
      cases.forEach((input, expected) {
        expect(AdaptiveDocument.parse(input).describe(), expected,
            reason: 'input was [$input]');
      });
    });

    test('html includes the title when present', () {
      expect(
        AdaptiveDocument.parse('<html><title>T</title></html>').describe(),
        'html page — T',
      );
    });
  });
}
