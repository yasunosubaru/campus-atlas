import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/i18n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../grades_query/jwgl/native_webview.dart';
import '../../whu_auth/whu_endpoints.dart' show JwglOrigin;
import 'jwgl_timetable_page_parser.dart';

/// Reads the timetable from the **rendered** N2151 page.
///
/// The data endpoint behind that page now answers an empty `kbList` unless the
/// person has just cleared the page's slider challenge. This screen follows the
/// same division of labour as the grade browser: the person clears the
/// challenge in the real page, the page draws the list, and the app copies the
/// already-visible rows. It never answers the challenge itself.
class JwglTimetableBrowserScreen extends StatefulWidget {
  const JwglTimetableBrowserScreen({super.key});

  static Future<JwglTimetablePage?> push(BuildContext context) =>
      Navigator.of(context).push<JwglTimetablePage>(
        MaterialPageRoute(
          builder: (_) => const JwglTimetableBrowserScreen(),
        ),
      );

  @override
  State<JwglTimetableBrowserScreen> createState() =>
      _JwglTimetableBrowserScreenState();
}

class _JwglTimetableBrowserScreenState
    extends State<JwglTimetableBrowserScreen> {
  final NativeWebView _webview = NativeWebView();
  bool _busy = true;
  String _failure = '';

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (!NativeWebView.isSupported) {
      setState(() {
        _busy = false;
        _failure = '此平台没有内置浏览器实现。';
      });
      return;
    }

    _webview.events.listen((event) {
      if (!mounted) return;
      if (event.kind == NativeWebViewEventKind.shown) {
        setState(() => _busy = false);
      }
      if (event.kind == NativeWebViewEventKind.failed) {
        setState(() {
          _busy = false;
          _failure = event.message ?? '内置浏览器启动失败';
        });
      }
    });

    final url = Uri.parse(JwglOrigin.timetablePage).replace(
      queryParameters: {
        'gnmkdm': JwglOrigin.timetableGnmkdm,
        'layout': 'default',
      },
    );
    try {
      await _webview.open(url.toString());
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = '${e.code}: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = '$e';
      });
    }
  }

  @override
  void dispose() {
    _webview.close();
    _webview.dispose();
    super.dispose();
  }

  Future<void> _withBrowserHidden(Future<void> Function() action) async {
    await _webview.close();
    await action();
    if (mounted) await _webview.show();
  }

  Future<void> _report(String body) async {
    final l10n = AppLocalizations.of(context);
    await _withBrowserHidden(
      () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.ttImportBrowserTitle),
          content: SingleChildScrollView(child: Text(body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        ),
      ),
    );
  }

  /// Switches to the page's list view, then reads its rows.
  ///
  /// The page's list view is the one with one row per course. The grid view is
  /// prettier but its cells repeat the course across many periods; the list is
  /// the exact shape the parser was written against.
  Future<void> _read(AppLocalizations l10n) async {
    setState(() {
      _busy = true;
      _failure = '';
    });

    try {
      await _webview.eval(_switchToListScript);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final payload = await _webview.evalJson(_readListScript);
      if (!mounted) return;

      final parsed = parseJwglTimetableList(payload);
      final failure = parsed.errorOrNull;
      if (failure != null) {
        setState(() => _busy = false);
        await _report('${l10n.ttImportBrowserNoRows}\n\n${failure.message}');
        return;
      }

      final result = parsed.requireValue;
      if (result.isEmpty) {
        setState(() => _busy = false);
        await _report(l10n.ttImportBrowserNoRows);
        return;
      }

      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _report('${l10n.ttImportBrowserNoRows}\n\n$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: kToolbarHeight,
        title: Text(l10n.ttImportBrowserTitle),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: l10n.signInCancel,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          IconButton(
            tooltip: l10n.ttImportBrowserRead,
            icon: const Icon(Icons.download_for_offline_outlined),
            onPressed: _busy ? null : () => _read(l10n),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceLg),
          child: _failure.isNotEmpty
              ? Text(
                  _failure,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: Theme.of(context).colorScheme.error),
                )
              : _busy
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: AppTheme.spaceMd),
                        Text('正在启动内置浏览器…'),
                      ],
                    )
                  : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

const String _switchToListScript = r'''
(function () {
  var found = document.querySelector('#kblist_table');
  if (found) return 'present';
  var els = document.querySelectorAll('a, button, span');
  for (var i = 0; i < els.length; i++) {
    var t = (els[i].innerText || els[i].textContent || '').trim();
    if (t === '列表') { els[i].click(); return 'clicked'; }
  }
  return 'missing';
})()
''';

const String _readListScript = r'''
(function () {
  var table = document.querySelector('#kblist_table');
  if (!table) {
    return JSON.stringify({
      ok: false,
      reason: '请先在页面点“查询”并完成滑块，再把视图切到“列表”。'
    });
  }
  var rows = [];
  var day = '';
  var trs = table.querySelectorAll('tr');
  for (var i = 0; i < trs.length; i++) {
    var cells = trs[i].cells;
    if (!cells || !cells.length) continue;
    var texts = [];
    for (var j = 0; j < cells.length; j++) {
      texts.push((cells[j].innerText || '').replace(/\s+/g, ' ').trim());
    }
    if (texts.length === 1 && /星期|周[一二三四五六日天]/.test(texts[0])) {
      day = texts[0];
      continue;
    }
    var p = -1;
    var c = -1;
    if (texts.length >= 2 && /^\d+(\s*-\s*\d+)?$/.test(texts[0])) {
      p = 0;
      c = 1;
    } else if (texts.length >= 3 && /星期|周/.test(texts[0]) &&
        /^\d+(\s*-\s*\d+)?$/.test(texts[1])) {
      // The period cell must be a period: the header row reads
      // 星期 | 节次 | 课表信息, and taking it for a course would count a
      // phantom skipped row in the import preview.
      day = texts[0];
      p = 1;
      c = 2;
    }
    if (p >= 0 && c >= 0 && texts[c]) {
      rows.push({day: day, periods: texts[p], text: texts[c]});
    }
  }
  if (!rows.length) {
    return JSON.stringify({
      ok: false,
      reason: '页面没有可读取的课表行；请先点“查询”并完成滑块。'
    });
  }
  var year = '';
  var term = '';
  var y = document.querySelector('#xnm');
  var t = document.querySelector('#xqm');
  if (y) year = y.value || '';
  if (t) term = t.value || '';
  return JSON.stringify({
    ok: true,
    year: year,
    term: term,
    rows: rows,
    title: document.title,
    url: location.href
  });
})()
''';
