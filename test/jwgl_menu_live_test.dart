import 'dart:io';

import 'package:campus_atlas/features/grades_query/jwgl/jwgl_menu.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parser, run against a menu a **live** student session actually served —
/// 70 KB of HTML, HTTP 200, captured from the request the app itself made after
/// adopting the browser's session.
///
/// This fixture exists because the parser's shape assumptions could not be
/// checked any other way: the menu is rendered into widgets that expose no text
/// to the accessibility tree, so "did the parse work" was unanswerable from the
/// running app. A capture answers it directly, and keeps answering it.
///
/// Two edits were made to the capture and nothing else: the signed-in student's
/// id was replaced with `REDACTED-ID`, and the diagnostic header the app wrote
/// above the response was dropped. The markup is otherwise byte-for-byte what the
/// server sent.
void main() {
  final html = File('test/fixtures/jwgl_menu_live.html').readAsStringSync();

  /// Entries by function code, which is the stable key across menu changes.
  Map<String, JwglMenuEntry> byCode(JwglMenu menu) => {
        for (final e in menu.all)
          if (e.gnmkdm.isNotEmpty) e.gnmkdm: e
      };

  group('the live menu', () {
    test('the capture is the real page, not a stub', () {
      // Guards the fixture itself: a truncated or replaced file would make every
      // assertion below pass for the wrong reason.
      expect(html, contains('教学管理信息服务平台'));
      expect(html, contains('clickMenu('));
      expect(html.length, greaterThan(50000));
      // The signed-in student's id was redacted when the page was captured;
      // it must stay redacted, and the placeholder must actually be there —
      // a capture that had lost it would look the same.
      expect(html, contains('REDACTED-ID'));
      expect(
          html, isNot(matches(RegExp(r'id="sessionUserKey" value="\d{6,}"'))));
    });

    test('the menu parses into entries', () {
      final menu = JwglMenu.parse(html);

      expect(menu.isEmpty, isFalse);
      // The capture holds 36 distinct `clickMenu` targets; a parser that found
      // only a handful would still be "non-empty" and still be wrong.
      expect(menu.all.length, greaterThan(20));
    });

    test('the pages the app links to by code are all in it', () {
      final codes = byCode(JwglMenu.parse(html));

      expect(codes['N305005']?.name, contains('成绩'));
      expect(codes['N105515']?.name, contains('学业'));
      expect(codes['N2151']?.name, contains('课表'));
      expect(codes['N305005']?.url, contains('/cjcx/cjcx_cxDgXscj.html'));
    });

    test('the evaluation entry is found, which is the point of the feature',
        () {
      // This is the row the whole feature was built for, and the one the parser
      // had to be taught to read: its destination is a `data-dyym` attribute
      // rather than the `clickMenu` call an ordinary entry uses.
      final menu = JwglMenu.parse(html);
      final hits = menu.evaluationEntries();

      expect(hits, isNotEmpty);
      expect(hits.any((e) => e.url.contains('ugsqs')), isTrue);
    });

    test('an entry with no destination is a group, not a dead link', () {
      // The live menu carries grouping labels whose own anchor points nowhere —
      // `报名申请` is one — with the useful rows underneath. Rendering a group as
      // a row is right; what would be wrong is a **leaf** with nothing to open,
      // because tapping it does nothing and no one can tell why.
      final menu = JwglMenu.parse(html);

      for (final e in menu.all.where((e) => e.children.isEmpty)) {
        expect(e.gnmkdm.isNotEmpty || e.url.isNotEmpty, isTrue,
            reason: 'leaf ${e.name} has neither a code nor a url');
      }
      expect(menu.all.where((e) => e.url.isNotEmpty).length, greaterThan(25));
    });
  });
}
