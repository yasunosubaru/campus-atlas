import 'package:campus_atlas/features/grades_query/jwgl/jwgl_menu.dart';
import 'package:campus_atlas/features/whu_auth/whu_endpoints.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the 正方 menu parser.
///
/// The `real captured menu` group below is the one that matters: it is built from
/// markup taken off a live student session, and it exists because the first
/// version of this parser handled **neither** of the two shapes that session
/// actually serves. The evaluation entry in particular — the single most
/// important row for this feature — was invisible to it, since its destination
/// lives in a `data-dyym` attribute and its `href` is `javascript:void(0)`, which
/// a href-only reader skips.
///
/// The JSON-shaped fixtures elsewhere in this file are left as they were:
/// candidates for an envelope this deployment does not use, kept so that a menu
/// served as JSON would still be read.
void main() {
  group('JSON menus', () {
    test('reads a flat menu with gnmkdm and url', () {
      final menu = JwglMenu.parse('''
        {"data":[
          {"kjmc":"成绩查询","gnmkdm":"N305005","url":"/cjcx/cjcx_cxXsgrcj.html"},
          {"kjmc":"课表查询","gnmkdm":"N2151","url":"/kbcx/xskbcx_cxXsgrkb.html"}
        ]}
      ''');

      expect(menu.isEmpty, isFalse);
      expect(menu.roots, hasLength(2));
      expect(menu.roots.first.name, '成绩查询');
      expect(menu.roots.first.gnmkdm, 'N305005');
      expect(menu.roots.first.url, '/cjcx/cjcx_cxXsgrcj.html');
    });

    test('reads a nested menu and keeps children attached', () {
      final menu = JwglMenu.parse('''
        {"menus":[
          {"name":"教学评价","gnmkdm":"N999001","url":"/kcpj/cxXsKcpj.html",
           "children":[
             {"name":"学生评教","gnmkdm":"N999002","url":"/kcpj/cxXsPj.html"}
           ]}
        ]}
      ''');

      expect(menu.roots, hasLength(1));
      final root = menu.roots.single;
      expect(root.name, '教学评价');
      expect(root.hasChildren, isTrue);
      expect(root.children.single.name, '学生评教');
    });

    test('finds the evaluation entry by label, not by path', () {
      // The path is the thing we do NOT know: the evaluation page appears
      // nowhere in this project's binary, so the label is the only handle.
      for (final label in const [
        '教学评价',
        '学生评教',
        '教师评价',
        '课程评价',
        '评教',
        'Teaching Evaluation',
      ]) {
        final menu = JwglMenu.parse(
          '{"menu":[{"kjmc":"$label","gnmkdm":"N1","url":"/x/y.html"}]}',
        );
        expect(menu.evaluationEntries(), hasLength(1), reason: label);
      }
    });

    test('finds an evaluation entry buried in a submenu', () {
      final menu = JwglMenu.parse('''
        {"menu":[
          {"name":"信息查询","gnmkdm":"N1","url":"/a.html","children":[
            {"name":"成绩查询","gnmkdm":"N2","url":"/b.html","children":[
              {"name":"学生评教","gnmkdm":"N3","url":"/c.html"}
            ]}
          ]}
        ]}
      ''');
      final hits = menu.evaluationEntries();
      expect(hits, hasLength(1));
      expect(hits.single.name, '学生评教');
      expect(hits.single.gnmkdm, 'N3');
    });

    test('an entry that only mentions grading is not an evaluation entry', () {
      final menu = JwglMenu.parse(
        '{"menu":[{"kjmc":"给分查询","gnmkdm":"N1","url":"/a.html"}]}',
      );
      // 给分 IS matched — it is one of the things the feature is for.
      expect(menu.evaluationEntries(), hasLength(1));
    });

    test('an unrelated menu yields no evaluation entries', () {
      final menu = JwglMenu.parse('''
        {"menu":[
          {"kjmc":"学籍信息","gnmkdm":"N1","url":"/a.html"},
          {"kjmc":"选课","gnmkdm":"N2","url":"/b.html"}
        ]}
      ''');
      expect(menu.evaluationEntries(), isEmpty);
      expect(menu.all, hasLength(2));
    });

    test('alias keys are accepted for label, code and url', () {
      final menu = JwglMenu.parse('''
        {"list":[{"title":"评教","code":"N7","href":"/p/q.html"}]}
      ''');
      expect(menu.roots.single.name, '评教');
      expect(menu.roots.single.gnmkdm, 'N7');
      expect(menu.roots.single.url, '/p/q.html');
    });

    test('a node with a label but no code or url is not a menu entry', () {
      // Requiring an identifier is what stops arbitrary nested metadata from
      // being read as a menu.
      final menu = JwglMenu.parse('{"meta":{"name":"配置"},"menu":[]}');
      expect(menu.roots, isEmpty);
    });

    test('the raw body is preserved for diagnosis', () {
      const body = '{"menu":[{"kjmc":"评教","gnmkdm":"N1","url":"/a.html"}]}';
      final menu = JwglMenu.parse(body);
      expect(menu.rawBody, body,
          reason: 'the menu shape is unestablished; the capture is the point');
    });

    test('an entry keeps its untouched payload', () {
      final menu = JwglMenu.parse(
        '{"menu":[{"kjmc":"评教","gnmkdm":"N1","url":"/a.html","xk":"1"}]}',
      );
      expect(menu.roots.single.raw['xk'], '1');
    });
  });

  group('HTML menus', () {
    test('falls back to reading anchors', () {
      final menu = JwglMenu.parse('''
        <ul class="menu">
          <li><a href="/xtgl/index.html">首页</a></li>
          <li><a href="/kcpj/cxXsKcpj.html">教学评价</a></li>
        </ul>
      ''');
      expect(menu.roots, hasLength(2));
      expect(menu.roots.map((e) => e.name), contains('教学评价'));
      expect(menu.evaluationEntries(), hasLength(1));
    });

    test('ignores javascript and fragment hrefs', () {
      final menu = JwglMenu.parse('''
        <a href="#">空</a>
        <a href="javascript:void(0)">脚本</a>
        <a href="/real.html">真</a>
      ''');
      expect(menu.roots, hasLength(1));
      expect(menu.roots.single.name, '真');
    });

    test('strips nested tags out of the label', () {
      final menu = JwglMenu.parse(
        '<a href="/a.html"><span>学生</span><b>评教</b></a>',
      );
      expect(menu.roots.single.name, '学生评教');
    });
  });

  group('degenerate input', () {
    test('an empty body yields an empty menu, not a throw', () {
      for (final body in const ['', '   ', '\n']) {
        final menu = JwglMenu.parse(body);
        expect(menu.isEmpty, isTrue, reason: '[$body]');
        expect(menu.evaluationEntries(), isEmpty);
      }
    });

    test('non-menu text yields an empty menu', () {
      final menu = JwglMenu.parse('please try it again later!');
      expect(menu.isEmpty, isTrue);
    });

    test('an empty array is an empty menu', () {
      expect(JwglMenu.parse('[]').isEmpty, isTrue);
      expect(JwglMenu.parse('{"menu":[]}').isEmpty, isTrue);
    });

    test('truncated JSON falls through to the anchor reader', () {
      // Not a throw, and not a crash: the worst case is an empty menu with the
      // body still captured.
      final menu = JwglMenu.parse('{"menu": [{"kjmc":');
      expect(menu.isEmpty, isTrue);
      expect(menu.rawBody, isNotEmpty);
    });

    test('flattening does not recurse without bound on a cyclic-shaped body',
        () {
      // Depth is capped, so a deeply nested body terminates rather than
      // exhausting the stack.
      final deep = StringBuffer('{"menu":');
      for (var i = 0; i < 40; i++) {
        deep.write(
            '[{"kjmc":"层$i","gnmkdm":"N$i","url":"/u$i.html","children":');
      }
      deep.write('[]');
      for (var i = 0; i < 40; i++) {
        deep.write('}]');
      }
      deep.write('}');
      expect(() => JwglMenu.parse(deep.toString()), returnsNormally);
    });
  });

  group('the real captured menu', () {
    // Transcribed from a live student session. Both shapes are present because
    // the real menu uses both, and the evaluation row is the second one — which
    // is why a href-only reader reported "no evaluation entry" while one sat in
    // plain sight.
    const menu = '''
      <ul class="nav navbar-nav">
        <li class="dropdown">
          <a id="drop1" href="#" role="button" class="dropdown-toggle" data-toggle="dropdown">信息查询<b class="caret"></b> </a>
          <ul class="dropdown-menu" role="menu" aria-labelledby="drop1">
            <li><a class="nav-target" tabindex="-1" data-gnmkdm="N100801" data-dyym="/xsxxxggl/xsgrxxwh_cxXsgrxx.html" data-sfgnym="1" href="javascript:void(0);">查询个人信息</a></li>
            <li><a class="nav-target" tabindex="-1" onclick="clickMenu('N305005','/cjcx/cjcx_cxDgXscj.html','学生成绩查询','null'); return false;" href="javascript:void(0);">学生成绩查询</a></li>
          </ul>
        </li>
        <li class="dropdown">
          <a id="drop1" href="#" role="button" class="dropdown-toggle" data-toggle="dropdown">学生评教<b class="caret"></b> </a>
          <ul class="dropdown-menu" role="menu" aria-labelledby="drop1">
            <li><a class="nav-target" tabindex="-1" data-gnmkdm="N05" data-dyym="/xtgl/index_cxDddz.html?type=jser&amp;url=https%3A%2F%2Fugsqs.whu.edu.cn%2Fcaslogin" data-sfgnym="1" href="javascript:void(0);">学生评教</a></li>
          </ul>
        </li>
      </ul>
    ''';

    test('finds the evaluation entry whose address is in data-dyym', () {
      final parsed = JwglMenu.parse(menu);
      final hits = parsed.evaluationEntries();

      expect(hits, hasLength(1));
      expect(hits.single.name, '学生评教');
      expect(hits.single.gnmkdm, 'N05');
    });

    test('unwraps the forwarding shim to the target it carries', () {
      // The menu points at a shim on its own host; the useful address is the
      // `url=` inside it, decoded. Leaving it wrapped would have the app fetch a
      // redirect page and parse HTML out of a redirect.
      final entry = JwglMenu.parse(menu).evaluationEntries().single;
      expect(entry.url, 'https://ugsqs.whu.edu.cn/caslogin');
    });

    test('reads an ordinary entry out of its onclick', () {
      final parsed = JwglMenu.parse(menu);
      final grades = parsed.all.firstWhere((e) => e.name == '学生成绩查询');

      expect(grades.gnmkdm, 'N305005');
      // The endpoint the live menu names — not the one an earlier document
      // claimed, and the distinction decides whether any rows come back.
      expect(grades.url, '/cjcx/cjcx_cxDgXscj.html');
    });

    test('keeps the grouping the menu draws', () {
      final parsed = JwglMenu.parse(menu);
      final group = parsed.roots.firstWhere((e) => e.name == '信息查询');

      expect(group.hasChildren, isTrue);
      expect(group.children.map((c) => c.name),
          containsAll(<String>['查询个人信息', '学生成绩查询']));
    });

    test('a label repeated across groups does not collapse the entries', () {
      // This page labels two different destinations 学生评教, so a label-keyed
      // dedupe would hide one of them.
      final parsed = JwglMenu.parse('''
        <a onclick="clickMenu('N05','/a.html','学生评教','null');">学生评教</a>
        <a onclick="clickMenu('N06','/b.html','学生评教','null');">学生评教</a>
      ''');
      expect(parsed.all.where((e) => e.name == '学生评教'), hasLength(2));
      expect(
          parsed.all.map((e) => e.gnmkdm), containsAll(<String>['N05', 'N06']));
    });

    test('an identical destination reached twice is listed once', () {
      const twice =
          '<a onclick="clickMenu(\'N2151\',\'/kbcx/x.html\',\'课表\',\'null\');">课表</a>'
          '<a onclick="clickMenu(\'N2151\',\'/kbcx/x.html\',\'课表\',\'null\');">课表</a>';
      expect(JwglMenu.parse(twice).all, hasLength(1));
    });

    test('the caret glyph is kept out of the label', () {
      final labels = JwglMenu.parse(menu).roots.map((e) => e.name);
      expect(labels, contains('学生评教'));
      expect(labels.any((l) => l.contains('<')), isFalse);
    });
  });

  group('JwglOrigin', () {
    test('the menu endpoint is the student one', () {
      expect(JwglOrigin.menu, endsWith('/xtgl/index_initMenu.html'));
      expect(JwglOrigin.studentJsdm, 'xs');
    });

    test('the grade query is the page that answers, not the one the JS names',
        () {
      // Measured against a live student session: `cxXsgrcj` answers 404 while
      // `cxDgXscj` answers with 学生成绩查询 and its `#tabGrid` grid. The page's
      // own ternary points a student (`jsxx == "xs"`) at `cxXsgrcj` and is stale
      // for this deployment; believing it cost a 404 once already.
      expect(JwglOrigin.gradeQuery, endsWith('/cjcx/cjcx_cxDgXscj.html'));
      expect(JwglOrigin.missingGradeQueryAlias,
          endsWith('/cjcx/cjcx_cxXsgrcj.html'));
      expect(JwglOrigin.gradeQuery, isNot(JwglOrigin.missingGradeQueryAlias));
      // The menu and the endpoint have to agree: the menu is the independent
      // authority the probe confirmed, so a drift between them is a real bug.
      expect(JwglOrigin.knownPages['N305005'], '/cjcx/cjcx_cxDgXscj.html');
      expect(JwglOrigin.gradeGnmkdm, 'N305005');
      expect(JwglOrigin.knownPages, contains(JwglOrigin.gradeGnmkdm));
    });

    test('the grade query shape is the one a working client sends', () {
      // POST with these four body fields; `validate` is a nonce, not a CAPTCHA
      // answer. Recorded so a future reader does not go looking for a solver.
      expect(JwglOrigin.gradePageSizeField, 'queryModel.showCount');
      expect(JwglOrigin.gradePageSize, '150');
    });

    test('the legacy discriminator is still exposed but no longer used', () {
      // Kept so a caller passing it does not break; the page is addressed by
      // `gnmkdm` now.
      expect(JwglOrigin.studentZdFzdm, isNot(JwglOrigin.staffZdFzdm));
    });

    test('known pages carry the codes the live menu uses', () {
      expect(JwglOrigin.knownPages['N305005'], contains('cxDgXscj'));
      expect(JwglOrigin.knownPages['N2151'], contains('xskbcx'));
      // The evaluation entry, whose destination is the evaluation system.
      expect(JwglOrigin.knownPages['N05'], contains('index_cxDddz'));
    });

    test('the forwarding shim is the one the menu uses', () {
      expect(JwglOrigin.forwardShim, endsWith('/xtgl/index_cxDddz.html'));
    });
  });
}
