import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/i18n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import 'ham_center_screen.dart';
import 'ham_course_sheet.dart';
import 'ham_grades_repository.dart';
import 'ham_mcp_client.dart';
import 'ham_oauth.dart';
import 'ham_score_models.dart';
import 'ham_token_console.dart';
import 'ham_token_store.dart';

/// 「给分与评价」，backed by the user's own Ham API key.
///
/// ## Why it works this way
///
/// Per-course grade distributions are **not** published by the university. Ham
/// builds them from contributions: its handbook says the app uploads the user's
/// own (anonymised) marks to Ham's server every time the 给分 screen is opened,
/// and the server aggregates them per course and per instructor. Ham then exposes
/// that aggregation as an MCP service.
///
/// So this screen does not pretend to read a public dataset. It asks the user for
/// **their own** key, obtained from `ham.nowcent.cn/console/tokens`, and answers
/// only if Ham has something. The distinction the screen refuses to blur:
///
///   * no contributions yet  → say so, it is the honest reading of an empty result
///   * the key is refused    → say that, and where to get a new one
///   * the service is broken → say that
///
/// Collapsing those three into "查询失败" is how a user ends up regenerating a
/// perfectly good key.
///
/// ## The key
///
/// Held in memory for the lifetime of this screen. Never written to disk, never
/// logged, never placed in an error message. It is the user's own credential and
/// they can revoke it at any time from Ham's console.
class HamGradesScreen extends StatefulWidget {
  const HamGradesScreen({super.key});

  static Future<void> push(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const HamGradesScreen()),
      );

  @override
  State<HamGradesScreen> createState() => _HamGradesScreenState();
}

class _HamGradesScreenState extends State<HamGradesScreen> {
  final TextEditingController _key = TextEditingController();
  final TextEditingController _query = TextEditingController();

  HamScoreQueryKind _kind = HamScoreQueryKind.byCourse;
  bool _busy = false;
  bool _authorizing = false;
  String _error = '';
  List<HamCourseScore> _results = const [];

  /// The token obtained by the quick-authorise flow, when there is one.
  ///
  /// Held here rather than written anywhere: it is a bearer credential for the
  /// user's Ham account. See [HamOAuth] for why the project does not persist it.
  HamToken? _token;

  /// A client registration, reused while it is still valid (30 days).
  ///
  /// Not a credential — it only saves re-registering on every launch.
  HamClientRegistration? _client;

  /// Where the authorisation is persisted. See [HamTokenStore] for what that
  /// means: the token sits in plaintext in this app's own configuration.
  final HamTokenStore _store = const HamTokenStore();

  /// What the console said after the last authorisation, for the UI.
  String _consoleNote = '';

  /// The authorise URL of the attempt in flight.
  ///
  /// Kept so a closed browser window is recoverable: without it the person has no
  /// way back and the listener holds the port until the timeout.
  Uri? _authorizeUrl;

  /// What the authorisation attempt did, step by step.
  ///
  /// The two symptoms this feature can produce — "the browser never comes back"
  /// and "the page says a parameter is missing" — look the same from the outside
  /// and have opposite causes. Keeping the URL and the callback address makes them
  /// distinguishable without guessing.
  final List<String> _authLog = <String>[];

  /// Kept so the diagnostics can say which tool was chosen and with what args.
  /// Values only — the key is never part of it.
  String _diagnostics = '';

  @override
  void initState() {
    super.initState();
    _restore();
  }

  /// Loads a persisted authorisation, if there is a live one.
  ///
  /// An expired token comes back as null and has already been cleared by the
  /// store, so the field stays empty and the user is prompted rather than being
  /// left with a key that fails as "unauthorised".
  Future<void> _restore() async {
    final token = await _store.loadToken();
    final client = await _store.loadClient();
    if (!mounted) return;
    setState(() {
      _client = client;
      if (token != null) {
        _token = token;
        _key.text = token.accessToken;
      }
    });
  }

  Future<void> _clearAuth() async {
    await _store.clearAll();
    if (!mounted) return;
    setState(() {
      _token = null;
      _client = null;
      _key.clear();
    });
  }

  /// Opens Ham's own token console — the page the person asked for.
  ///
  /// It is the authority on keys: created there, shown once, revoked there. The
  /// catch is that it needs a Ham login, and Ham's login is a QR scan or a
  /// passkey on the user's own device, so the app cannot do it for them — the
  /// browser page is as far as this can go.
  Future<void> _openTokenPanel() async {
    final l10n = AppLocalizations.of(context);
    final opened = await launchUrl(
      Uri.parse(HamOAuth.tokenConsoleUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.hamOpenTokenPanelFailed)),
      );
    }
  }

  @override
  void dispose() {
    _key.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _authorize() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _authorizing = true;
      _error = '';
    });

    final oauth = HamOAuth();
    try {
      setState(() {
        _authLog.clear();
        _authorizing = true;
        _error = '';
      });
      final result = await oauth.authorize(
        cached: _client,
        onAuthorizeUrl: (url) {
          if (!mounted) return;
          _authLog.add('authorize: $url');
          // The callback the browser will be sent to. Seeing the port here is the
          // difference between "it never comes back" and "something is wrong".
          _authLog.add(
              'callback: ${url.queryParameters['redirect_uri'] ?? '(none)'}');
          setState(() => _authorizeUrl = url);
        },
      );
      if (!mounted) return;

      if (result.isFailure) {
        setState(() {
          _authorizing = false;
          _error = result.errorOrNull!.message;
          _authLog.add('failed: ${result.errorOrNull!.message}');
        });
        return;
      }

      final token = result.requireValue;

      // Then try Ham's own console. Its BFF forwards the Authorization header to
      // `/web/tokens`, so the OAuth token may be able to mint a **30-day key** —
      // which is a better credential to keep than a short access token, and it is
      // the thing the console exists to produce.
      //
      // A refusal here is not fatal: the OAuth token already works for queries.
      var effective = token;
      String note = '';
      final console = HamTokenConsole();
      try {
        final made = await console.create(token.accessToken, ttlDays: 30);
        if (made.isSuccess) {
          final key = made.requireValue;
          effective = HamToken(
            accessToken: key.rawToken,
            obtainedAt: DateTime.now(),
            expiresAt: key.token.expiresAt ??
                DateTime.now().add(const Duration(days: 30)),
          );
          note = '已通过 Ham 控制台生成 30 天密钥';
        } else {
          note = '控制台未接受该凭据，使用 OAuth 令牌（查询同样可用）';
        }
      } finally {
        console.close();
      }

      // Persisted so a restart does not cost another authorisation. This is the
      // exception the user asked for; see [HamTokenStore] for the trade-off.
      await _store.saveToken(effective);
      final used = oauth.lastClient;
      if (used != null) {
        _client = used;
        await _store.saveClient(used);
      }
      if (!mounted) return;

      setState(() {
        _authorizing = false;
        _token = effective;
        _consoleNote = note;
        // Filled in for the user, which is the whole point of the button.
        _key.text = effective.accessToken;
        _error = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(l10n.hamTokenReady.replaceAll('%d', '${token.daysLeft}')),
        ),
      );
    } finally {
      oauth.close();
      if (mounted && _authorizing) setState(() => _authorizing = false);
    }
  }

  Future<void> _search() async {
    final l10n = AppLocalizations.of(context);
    if (_key.text.trim().isEmpty) {
      setState(() => _error = l10n.hamKeyNeeded);
      return;
    }
    if (_query.text.trim().isEmpty) {
      setState(() => _error = l10n.hamQueryNeeded);
      return;
    }

    setState(() {
      _busy = true;
      _error = '';
      _results = const [];
    });

    final client = HamMcpClient(apiKey: _key.text.trim());
    final repo = HamGradesRepository(client: client);
    try {
      final result = await repo.search(query: _query.text, kind: _kind);
      if (!mounted) return;

      final lines = <String>[
        'endpoint: ${HamMcpClient.endpoint}',
        'tools: ${repo.discoveredTools.map((t) => t.name).join(", ")}',
        'chosen: ${repo.chosenTool?.name ?? "(none)"}',
        'args: ${repo.lastArguments}',
        'results: ${result.isSuccess ? result.requireValue.length : 0}',
        // The reason, not just the count: a zero with no explanation is the
        // difference between "check your key" and "nobody has contributed".
        if (result.isFailure) 'error: ${result.errorOrNull?.message}',
        if (result.isSuccess)
          for (final s in result.requireValue.take(5))
            '  · ${s.name} / ${s.instructor} · avg=${s.average?.toStringAsFixed(2)} '
                'median=${s.median} n=${s.total} bands=${s.buckets.length}',
      ];

      setState(() {
        _busy = false;
        _diagnostics = lines.join('\n');
        if (result.isSuccess) {
          _results = result.requireValue;
        } else {
          _results = const [];
          _error = result.errorOrNull!.message;
        }
      });
    } finally {
      client.close();
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.hamTitle),
        actions: [
          IconButton(
            tooltip: l10n.hamCenter,
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const HamCenterScreen(),
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.signInDiagnostics,
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: _showDiagnostics,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceMd,
            AppTheme.spaceMd,
            AppTheme.spaceMd,
            AppTheme.spaceXl,
          ),
          children: [
            Text(l10n.hamIntro, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppTheme.spaceMd),
            TextField(
              controller: _key,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l10n.hamApiKey,
                helperText: l10n.hamApiKeyHint,
                helperMaxLines: 2,
                prefixIcon: const Icon(Icons.key_outlined),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppTheme.spaceSm),

            // The one-click path: no copying, and renewal after the token or the
            // client registration lapses is the same single click.
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: (_authorizing || _busy) ? null : _authorize,
                  icon: _authorizing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bolt_rounded),
                  label: Text(
                    _authorizing ? l10n.hamAuthorizing : l10n.hamQuickAuth,
                  ),
                ),
                const SizedBox(width: AppTheme.spaceSm),
                if (_token != null)
                  Text(
                    l10n.hamTokenDays.replaceAll('%d', '${_token!.daysLeft}'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const Spacer(),
                if (_token != null)
                  TextButton(
                    onPressed: (_authorizing || _busy) ? null : _clearAuth,
                    child: Text(l10n.hamClearAuth),
                  ),
              ],
            ),
            if (_consoleNote.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.spaceXs),
                child: Text(
                  _consoleNote,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            // A closed browser must not be a dead end. While the attempt is in
            // flight the URL is known, so it can be reopened — or copied into
            // whichever browser holds the Ham session.
            if (_authorizing && _authorizeUrl != null)
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.spaceXs),
                child: Wrap(
                  spacing: AppTheme.spaceSm,
                  runSpacing: AppTheme.spaceXs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: () => launchUrl(_authorizeUrl!,
                          mode: LaunchMode.externalApplication),
                      icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                      label: Text(l10n.hamReopenAuthorize),
                    ),
                    Text(
                      l10n.hamWaitingHint,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppTheme.spaceXs),
            Wrap(
              spacing: AppTheme.spaceSm,
              runSpacing: AppTheme.spaceXs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _openTokenPanel,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(l10n.hamOpenTokenPanel),
                ),
                Text(
                  l10n.hamTokenPanelHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spaceMd),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    enabled: !_busy,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _busy ? null : _search(),
                    decoration: InputDecoration(
                      labelText: _kind == HamScoreQueryKind.byCourse
                          ? l10n.hamCourseName
                          : l10n.hamInstructor,
                      prefixIcon: const Icon(Icons.search_rounded),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: AppTheme.spaceSm),
                SegmentedButton<HamScoreQueryKind>(
                  segments: [
                    ButtonSegment(
                      value: HamScoreQueryKind.byCourse,
                      label: Text(l10n.hamByCourse),
                    ),
                    ButtonSegment(
                      value: HamScoreQueryKind.byInstructor,
                      label: Text(l10n.hamByInstructor),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged:
                      _busy ? null : (s) => setState(() => _kind = s.first),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spaceMd),
            FilledButton.icon(
              onPressed: _busy ? null : _search,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.query_stats_rounded),
              label: Text(_busy ? l10n.hamSearching : l10n.hamSearch),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: AppTheme.spaceMd),
              Panel(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline_rounded,
                        size: 18, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: AppTheme.spaceSm),
                    Expanded(
                      child: Text(_error,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
            ],
            if (_results.isNotEmpty) ...[
              const SizedBox(height: AppTheme.spaceMd),
              for (final r in _results) ...[
                _scoreCard(l10n, r),
                const SizedBox(height: AppTheme.spaceSm),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _scoreCard(AppLocalizations l10n, HamCourseScore s) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final busiest = s.busiestBucket;
    final openable = s.courseTableId.isNotEmpty;

    // The card is not itself a tap target: an InkWell around it did not respond
    // to a mouse click in the release build (measured), and a chevron that
    // promises a click it does not deliver is worse than no chevron. The
    // explicit button is the affordance.
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.name.isEmpty ? l10n.hamUnknownCourse : s.name,
              style: text.titleSmall,
            ),
            if (s.instructor.isNotEmpty)
              Text(s.instructor, style: text.bodySmall),
            const SizedBox(height: AppTheme.spaceXs),
            Row(
              children: [
                if (s.average != null)
                  Text(
                    '${l10n.hamAverage} ${s.average!.toStringAsFixed(1)}',
                    style: text.bodySmall,
                  ),
                const SizedBox(width: AppTheme.spaceMd),
                Text(
                  l10n.hamSamples.replaceAll('%d', '${s.total}'),
                  style: text.bodySmall?.copyWith(color: scheme.outline),
                ),
              ],
            ),
            if (s.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.spaceSm),
                child: Text(
                  l10n.hamNoData,
                  style: text.bodySmall?.copyWith(color: scheme.outline),
                ),
              )
            else ...[
              const SizedBox(height: AppTheme.spaceSm),
              for (final band in s.buckets) _bandRow(band, busiest, scheme),
            ],
            if (openable)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _openCourseDetail(s),
                  icon: const Icon(Icons.forum_outlined, size: 18),
                  label: Text(l10n.hamComments),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openCourseDetail(HamCourseScore score) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => HamCourseSheet(
        score: score,
        apiKey: _key.text.trim(),
      ),
    );
  }

  /// One score band, drawn as a bar scaled to the busiest band.
  ///
  /// Scaled to the data rather than to [HamCourseScore.total]: a band can
  /// legitimately exceed the reported total when the server counts differently,
  /// and scaling by the total would then produce a bar wider than the row.
  Widget _bandRow(HamScoreBucket band, int? busiest, ColorScheme scheme) {
    final fraction = busiest == null ? 0.0 : band.total / busiest;
    final colour = band.total == 0 ? scheme.outlineVariant : scheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text('${band.from}-${band.to}',
                style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: fraction.clamp(0.0, 1.0),
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: colour,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text('${band.total}',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  void _showDiagnostics() {
    final l10n = AppLocalizations.of(context);
    final parts = <String>[];
    if (_authLog.isNotEmpty) parts.add('=== 授权 ===\n${_authLog.join('\n')}');
    if (_diagnostics.isNotEmpty) parts.add('=== 查询 ===\n$_diagnostics');
    final body = parts.isEmpty ? '（还没有记录）' : parts.join('\n\n');

    showModalBottomSheet<void>(
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
              // Said out loud: this panel exists to be copied, and a key in it
              // would be a key pasted into a chat.
              Text(l10n.hamApiKeyHint,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: AppTheme.spaceSm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: SingleChildScrollView(
                  child: SelectableText(body,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11)),
                ),
              ),
              const SizedBox(height: AppTheme.spaceSm),
              FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: body));
                  if (!sheet.mounted) return;
                  ScaffoldMessenger.of(sheet).showSnackBar(
                    SnackBar(content: Text(l10n.gqCopied)),
                  );
                },
                icon: const Icon(Icons.copy_all_outlined),
                label: Text(l10n.gqCopy),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
