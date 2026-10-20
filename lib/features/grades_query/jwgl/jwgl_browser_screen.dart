import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/i18n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../main.dart';
import '../../whu_auth/browser_session.dart';
import '../../whu_auth/whu_endpoints.dart' show JwglOrigin;
import '../../whu_auth/whu_session.dart' show WhuProperty;
import '../archive/grade_archive_repository.dart';
import '../archive/grade_archive_screen.dart';
import '../archive/grade_import.dart';
import 'jwgl_grade_grid.dart';
import 'native_webview.dart';

/// A page that has to run in a real browser, shown inside the app's window.
///
/// ## Why this screen exists
///
/// The academic system gates its grade query behind an anti-bot puzzle. There is
/// no honest way for this app to answer one on the person's behalf, so it shows
/// the **real page in the real engine** and lets them do it. The app then reads
/// the reply as text.
///
/// That is the same division of labour Ham uses — its own note says the person
/// solves the challenge in the page and the app reads the result — and it is why
/// the browser is hosted by the Windows runner rather than by a Flutter platform
/// view. See [NativeWebView] for the release-build rendering failure that ruled
/// the platform view out.
///
/// ## The layout
///
/// The browser covers the client area **below a reserved strip** that the native
/// host leaves for this app bar. Without that strip the page would swallow the
/// whole window, including the only control that closes it.
class JwglBrowserScreen extends StatefulWidget {
  const JwglBrowserScreen({
    super.key,
    required this.url,
    required this.title,
    this.showGradeTools = true,
  });

  final String url;
  final String title;

  /// Whether the grade-specific buttons are shown.
  ///
  /// The screen hosts a general WebView; the evaluation entry reuses it. Leaving
  /// the grade buttons visible there would offer actions for a page that is not
  /// the grade page, so the caller can turn them off.
  final bool showGradeTools;

  static Future<void> push(
    BuildContext context, {
    required String url,
    required String title,
    bool showGradeTools = true,
  }) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => JwglBrowserScreen(
            url: url,
            title: title,
            showGradeTools: showGradeTools,
          ),
        ),
      );

  @override
  State<JwglBrowserScreen> createState() => _JwglBrowserScreenState();
}

class _JwglBrowserScreenState extends State<JwglBrowserScreen> {
  final NativeWebView _webview = NativeWebView();
  final List<String> _log = <String>[];
  String _failure = '';
  bool _busy = true;

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
      setState(() {
        _log.add(
            '${event.kind.name}${event.message == null ? '' : ': ${event.message}'}');
        if (event.kind == NativeWebViewEventKind.shown) _busy = false;
        if (event.kind == NativeWebViewEventKind.failed) {
          _busy = false;
          _failure = event.message ?? '内置浏览器启动失败';
        }
      });
    });

    try {
      await _webview.open(widget.url);
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
    // Hiding rather than destroying: the page keeps its session if the caller
    // comes back, and the host stays allocated for the next screen that needs it.
    _webview.close();
    _webview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        // The native host reserves exactly this height above the browser.
        toolbarHeight: kToolbarHeight,
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: l10n.signInCancel,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          // Hands this browser's cookies to the app. This is what makes one
          // sign-in enough for everything: after it, the menu, the credit
          // progress and the evaluation entry all run off the session the person
          // just established here — a session they could not have established at
          // the app's own prompt, because the puzzle is not presented there.
          //
          // It belongs on this screen rather than the previous one for the same
          // reason the deep link does: the cookies only exist while this browser
          // holds them.
          IconButton(
            tooltip: l10n.jwAdoptSession,
            icon: const Icon(Icons.vpn_key_outlined),
            onPressed: _busy ? null : () => _adoptSession(l10n),
          ),
          // Navigating the *same* browser is the only way a deep link works.
          //
          // The academic system's session cookie is session-scoped: it lives in
          // the browser's memory, so it is gone the moment that browser closes. A
          // fresh screen — or a fresh app run — starts signed out. This button
          // therefore belongs here, where the session is certainly alive, rather
          // than on the screen before it.
          if (widget.showGradeTools) ...[
            IconButton(
              tooltip: l10n.jwGoToGrades,
              icon: const Icon(Icons.table_chart_outlined),
              onPressed: () => _goToGrades(l10n),
            ),
            // Reads the grid that is already on screen. Placed next to the
            // navigation button because the two are used in sequence: go to the
            // page, run the query (a person clears the puzzle), then read.
            IconButton(
              tooltip: l10n.jwReadGrades,
              icon: const Icon(Icons.download_for_offline_outlined),
              onPressed: _busy ? null : () => _readGrades(l10n),
            ),
          ],
          IconButton(
            tooltip: l10n.signInDiagnostics,
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => _withBrowserHidden(_showLog),
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

  /// Takes the browser's cookies as the app's own session.
  ///
  /// The person signs in **once**, here, where whatever the page asks for can
  /// actually be answered — and every feature that does not itself need the
  /// puzzle then works off these cookies. Before this, the app's own client and
  /// this browser held two unrelated sessions and neither one was enough.
  Future<void> _adoptSession(AppLocalizations l10n) async {
    setState(() {
      _busy = true;
      _failure = '';
    });

    try {
      // Both origins, because WebView2 matches cookies on the path as well as
      // the host and the CAS grant lives at `/authserver`.
      final cookies =
          await _webview.cookies(browserHarvestUrls(WhuProperty.jwgl));
      if (!mounted) return;

      final result = sessionFromBrowserCookies(cookies);
      final session = result.dataOrNull;
      setState(() => _busy = false);

      if (session == null) {
        // Most often: the sign-in has not happened yet, so there is no CASTGC to
        // extend from. The failure names which cookie is missing, which is the
        // difference between "sign in first" and "something is wrong".
        await _report(
            '${l10n.jwAdoptFailed}${result.errorOrNull?.message ?? ''}');
        return;
      }

      AppScope.of(context, dependOn: false).whuSession = session;
      // A dialog over the hidden browser, not a snackbar: the browser is stacked
      // above the Flutter view, so a snackbar at the bottom would be behind the
      // page. The handshake line is included because it names which cookies the
      // session actually holds — the first thing worth knowing when a later
      // request is refused — and it carries no cookie value.
      await _report('${l10n.jwAdoptOk}\n\n${session.handshake.join('\n')}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _report('${l10n.jwAdoptFailed}$e');
    }
  }

  /// Renders a script payload for a person to read.
  ///
  /// A failure envelope is a map of facts; joining them is more useful than
  /// `Map.toString()`, which is what a hint-free "nothing found" amounts to.
  String _describePayload(Object? payload) {
    if (payload is Map) {
      return payload.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    }
    return payload == null ? '(脚本没有留下结果 —— 它可能根本没有执行)' : '$payload';
  }

  /// Navigates the **existing** browser to the grade query.
  ///
  /// Same instance, same cookie jar, so a session established a moment ago is
  /// still in it. Pushing a new screen would not work: the academic system's
  /// session cookie is session-scoped and dies with the browser that holds it.
  Future<void> _goToGrades(AppLocalizations l10n) async {
    final url = Uri.parse(JwglOrigin.gradeQuery).replace(
      queryParameters: {
        'gnmkdm': JwglOrigin.gradeGnmkdm,
        'layout': 'default',
      },
    );
    try {
      await _webview.open(url.toString());
    } catch (e) {
      if (!mounted) return;
      setState(() => _failure = '$e');
    }
  }

  /// Reads the grade grid out of the page and shows it.
  ///
  /// This is the whole point of hosting a browser: the person clears the puzzle,
  /// the page renders the grid, and the app copies the rendered text. No
  /// verification happens here.
  Future<void> _readGrades(AppLocalizations l10n) async {
    setState(() {
      _busy = true;
      _failure = '';
    });

    // Run it, then read the answer back out of the variable it wrote.
    //
    // The first call's own value is deliberately ignored: WebView2 answers a
    // script with no completion value with the four characters `null`, which is
    // indistinguishable from a real `null`. Awaiting it still matters — it is
    // what says the script has finished — and the read-back is then unambiguous.
    await _webview.evalJson(gradeGridRunScript);
    final payload = await _webview.evalJson('window.$gradeGridVariable');
    if (!mounted) return;

    final grid = JwglGradeGrid.tryParse(payload);
    setState(() => _busy = false);

    if (grid == null) {
      // The script answers with an envelope rather than a grid when it cannot find
      // one. Its details are shown rather than a flat "nothing found": the url, the
      // title and the table count say immediately whether the page is the grade
      // page at all, or a login or maintenance page that merely has its address.
      await _report('${l10n.jwNoGrades}\n\n${_describePayload(payload)}');
      return;
    }
    // An empty grid is shown rather than reported as a failure: the grid explains
    // itself (`请选择筛选条件!` / `无数据显示`), and that is a real answer that says
    // what to do next, where "reading failed" would not.
    //
    // Whatever was read is archived first, so the sheet can say what was kept.
    // A merge that fails is reported inside the sheet instead of swallowed: the
    // read succeeded, and the difference between "read" and "kept" is exactly
    // what the statistics depend on.
    GradeMergeResult? archived;
    String archiveFailure = '';
    if (!grid.isEmpty) {
      final records = recordsFromGrid(grid);
      if (records.isNotEmpty) {
        final merged =
            await AppScope.of(context, dependOn: false).gradeArchive.merge(records);
        if (!mounted) return;
        archived = merged.dataOrNull;
        final failure = merged.errorOrNull;
        if (failure != null) archiveFailure = failure.message;
      }
    }

    var openStats = false;
    await _withBrowserHidden(
      () => _showGrid(
        grid,
        l10n,
        archived: archived,
        archiveFailure: archiveFailure,
        onOpenStats: archived == null ? null : () => openStats = true,
      ),
    );

    if (!mounted || !openStats) return;
    // Getting to the statistics means leaving the browser: the page is a native
    // child window stacked above everything Flutter draws, so the archive
    // screen would otherwise open behind it. Nothing is lost — the grid was
    // just read, and the archive outlives the session on purpose.
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const GradeArchiveScreen()),
    );
  }

  Future<void> _showGrid(
    JwglGradeGrid grid,
    AppLocalizations l10n, {
    GradeMergeResult? archived,
    String archiveFailure = '',
    VoidCallback? onOpenStats,
  }) {
    // The columns worth showing, resolved through the grid's own field names
    // first and by label only as a fallback — `学分` is a substring of `学分绩点`,
    // so label matching alone can put the wrong column first.
    final order = <int>[];
    for (final (field, label) in JwglGradeFields.ordered) {
      final index = grid.columnFor(field, label);
      if (index >= 0 && !order.contains(index)) order.add(index);
    }
    if (order.isEmpty) {
      for (var i = 0; i < grid.head.length; i++) {
        order.add(i);
      }
    }

    final nameIndex = grid.columnFor(JwglGradeFields.courseName, '课程名称');
    final scoreIndex = grid.columnFor(JwglGradeFields.score, '成绩');
    final pointIndex = grid.columnFor(JwglGradeFields.gradePoint, '绩点');

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceMd),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.jwReadGrades,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppTheme.spaceXs),
              Text(grid.summary, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: AppTheme.spaceSm),
              if (grid.isEmpty)
                // The grid's own words, kept verbatim: `请选择筛选条件!` means the
                // query has not been run, `无数据显示` means it has and found
                // nothing. Those need different things from the person.
                Text(
                  grid.notice.isEmpty ? l10n.jwNoGrades : grid.notice,
                  style: Theme.of(context).textTheme.bodyMedium,
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: grid.rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 12),
                    itemBuilder: (_, i) {
                      final row = grid.rows[i];
                      String cell(int index) =>
                          index >= 0 && index < row.length ? row[index] : '';
                      final name = cell(nameIndex);
                      final score = cell(scoreIndex);
                      final point = cell(pointIndex);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.isEmpty ? '第${i + 1}行' : name,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          if (score.isNotEmpty || point.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                [
                                  if (score.isNotEmpty) '成绩 $score',
                                  if (point.isNotEmpty) '绩点 $point',
                                ].join(' · '),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                              ),
                            ),
                          for (final index in order)
                            if (index != nameIndex &&
                                index != scoreIndex &&
                                index != pointIndex &&
                                index < row.length &&
                                row[index].isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  '${grid.labelAt(index)}：${row[index]}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                        ],
                      );
                    },
                  ),
                ),
              if (archived != null) ...[
                const SizedBox(height: AppTheme.spaceSm),
                Text(
                  archived.changed
                      ? l10n.archiveArchived
                          .replaceFirst('%d', '${archived.total}')
                          .replaceFirst('%n', '${archived.added}')
                          .replaceFirst('%u', '${archived.updated}')
                      : l10n.archiveUnchanged
                          .replaceFirst('%d', '${archived.total}'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
              ],
              if (archiveFailure.isNotEmpty) ...[
                const SizedBox(height: AppTheme.spaceSm),
                Text(
                  l10n.archiveFailed.replaceFirst('%s', archiveFailure),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
              ],
              const SizedBox(height: AppTheme.spaceSm),
              Wrap(
                spacing: AppTheme.spaceSm,
                runSpacing: AppTheme.spaceXs,
                children: [
                  FilledButton.icon(
                    onPressed: () async {
                      // The summary goes first. Without it the copied text cannot say
                      // *which* table was read — and when the numbers look wrong, that
                      // is the first question worth answering.
                      final raw = [
                        grid.summary,
                        '',
                        ...grid.asFieldMaps.map((r) => r.entries
                            .map((e) => '${e.key}=${e.value}')
                            .join(' | ')),
                      ].join('\n');
                      await Clipboard.setData(ClipboardData(text: raw));
                      if (!sheet.mounted) return;
                      ScaffoldMessenger.of(sheet).showSnackBar(
                        SnackBar(content: Text(l10n.gqCopied)),
                      );
                    },
                    icon: const Icon(Icons.copy_all_outlined),
                    label: Text(l10n.gqCopy),
                  ),
                  if (onOpenStats != null)
                    FilledButton.tonalIcon(
                      onPressed: () {
                        // Closing the sheet is all this does; the screen it
                        // opened from leaves the browser and pushes the archive
                        // once the sheet's future completes, which is what
                        // makes the order safe.
                        Navigator.of(sheet).pop();
                        onOpenStats();
                      },
                      icon: const Icon(Icons.insights_outlined),
                      label: Text(l10n.archiveViewStats),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Runs [surface] with the browser hidden, then brings it back.
  ///
  /// The browser is a **native child window stacked above the Flutter view**, so
  /// anything Flutter draws below the reserved top strip is behind it — a sheet or
  /// a dialog opens where nobody can see it. Hiding the browser for the duration
  /// is what makes a result readable. The page keeps running while hidden, so its
  /// session survives and nothing has to be re-fetched.
  Future<void> _withBrowserHidden(Future<void> Function() surface) async {
    await _webview.close();
    try {
      await surface();
    } finally {
      // In a `finally`: a result surface that throws must not leave the person
      // staring at a Flutter screen with no way back to the page.
      await _webview.show();
    }
  }

  /// Reports something the person has to read, over the hidden browser.
  ///
  /// The 复制 action is not decoration: this dialog is where a failure explains
  /// itself, and the clipboard is the only way that explanation leaves the app.
  Future<void> _report(String message) {
    final l10n = AppLocalizations.of(context);

    return _withBrowserHidden(() async {
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          content: SingleChildScrollView(child: SelectableText(message)),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: message));
                if (!dialog.mounted) return;
                ScaffoldMessenger.of(dialog).showSnackBar(
                  SnackBar(content: Text(l10n.gqCopied)),
                );
              },
              icon: const Icon(Icons.copy_all_outlined),
              label: Text(l10n.gqCopy),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _showLog() {
    final l10n = AppLocalizations.of(context);
    final body = _log.isEmpty ? '（无记录）' : _log.join('\n');

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceMd),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.signInDiagnostics,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppTheme.spaceXs),
              Text(widget.url, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: AppTheme.spaceSm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: SingleChildScrollView(
                  child: SelectableText(body,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
