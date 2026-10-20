import 'package:flutter/material.dart';

import '../../../core/i18n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import 'ham_center_models.dart';
import 'ham_center_repository.dart';
import 'ham_mcp_client.dart';
import 'ham_token_store.dart';

/// 我的 Ham — profile, rank, want list and own comments.
///
/// Everything here is a **read**. Submitting a grade or writing a comment is not
/// exposed by Ham's MCP tools (the 13-tool inventory has no such entry), so this
/// screen does not offer it; the introduction says so rather than leaving a
/// missing button unexplained.
class HamCenterScreen extends StatefulWidget {
  const HamCenterScreen({super.key, this.repository});

  /// Injected by tests; production builds one from the stored token.
  final HamCenterRepository? repository;

  @override
  State<HamCenterScreen> createState() => _HamCenterScreenState();
}

class _HamCenterScreenState extends State<HamCenterScreen> {
  HamCenterRepository? _repository;
  bool _ownsRepository = false;

  bool _loading = true;
  bool _needsAuth = false;

  HamUserInfo? _user;
  HamLooseSection? _rank;
  HamLooseSection? _wants;
  HamCommentPage? _comments;

  String _userError = '';
  String _rankError = '';
  String _wantsError = '';
  String _commentsError = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (_ownsRepository) _repository?.close();
    super.dispose();
  }

  Future<void> _load() async {
    var repository = widget.repository;
    var owns = false;

    if (repository == null) {
      final token = await const HamTokenStore().loadToken();
      if (!mounted) return;
      if (token == null) {
        setState(() {
          _loading = false;
          _needsAuth = true;
        });
        return;
      }
      repository = HamCenterRepository(
        gateway: HamMcpGateway(HamMcpClient(apiKey: token.accessToken)),
      );
      owns = true;
    }

    _repository = repository;
    _ownsRepository = owns;

    final user = await repository.userInfo();
    final rank = await repository.scoreRank();
    final wants = await repository.wantList();
    final comments = await repository.myComments();

    if (!mounted) {
      if (owns) repository.close();
      return;
    }
    setState(() {
      _loading = false;
      _user = user.dataOrNull;
      _userError = user.errorOrNull?.message ?? '';
      _rank = rank.dataOrNull;
      _rankError = rank.errorOrNull?.message ?? '';
      _wants = wants.dataOrNull;
      _wantsError = wants.errorOrNull?.message ?? '';
      _comments = comments.dataOrNull;
      _commentsError = comments.errorOrNull?.message ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.hamCenter)),
      body: _loading
          ? const CenterLoader()
          : _needsAuth
              ? EmptyState(
                  title: l10n.hamNeedAuthTitle,
                  body: l10n.hamNeedAuthBody,
                  icon: Icons.key_outlined,
                )
              : _content(l10n),
    );
  }

  Widget _content(AppLocalizations l10n) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceMd,
        AppTheme.spaceMd,
        AppTheme.spaceMd,
        AppTheme.spaceXl,
      ),
      children: [
        Text(l10n.hamCenterIntro, style: text.bodySmall),
        const SizedBox(height: AppTheme.spaceMd),
        if (_user != null) _profile(_user!, text, scheme),
        if (_userError.isNotEmpty)
          _errorLine(l10n, _userError, text, scheme),
        const SizedBox(height: AppTheme.spaceMd),
        SectionHeader(l10n.hamRank),
        _looseSection(
          l10n,
          _rank,
          _rankError,
          l10n.hamNoRank,
          text,
          scheme,
        ),
        const SizedBox(height: AppTheme.spaceMd),
        SectionHeader(l10n.hamWant),
        _looseSection(
          l10n,
          _wants,
          _wantsError,
          l10n.hamNoWant,
          text,
          scheme,
        ),
        const SizedBox(height: AppTheme.spaceMd),
        SectionHeader(l10n.hamMyComments),
        _myComments(l10n, text, scheme),
      ],
    );
  }

  Widget _profile(HamUserInfo user, TextTheme text, ColorScheme scheme) {
    return Panel(
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: scheme.primaryContainer,
            backgroundImage:
                user.avatarUrl.isEmpty ? null : NetworkImage(user.avatarUrl),
            child: user.avatarUrl.isEmpty
                ? Icon(Icons.person_outline, color: scheme.onPrimaryContainer)
                : null,
          ),
          const SizedBox(width: AppTheme.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user.nickname, style: text.titleMedium),
                Text('Ham', style: text.bodySmall?.copyWith(color: scheme.outline)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _looseSection(
    AppLocalizations l10n,
    HamLooseSection? section,
    String error,
    String emptyText,
    TextTheme text,
    ColorScheme scheme,
  ) {
    if (error.isNotEmpty) return _errorLine(l10n, error, text, scheme);
    if (section == null) return const SizedBox.shrink();

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.hamTotalCount.replaceAll('%d', '${section.total}'),
            style: text.bodySmall?.copyWith(color: scheme.outline),
          ),
          if (section.items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.spaceXs),
              child: Text(
                emptyText,
                style: text.bodySmall?.copyWith(color: scheme.outline),
              ),
            )
          else
            for (final item in section.items)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(item.title.isEmpty ? '—' : item.title),
                subtitle: item.subtitle.isEmpty
                    ? null
                    : Text(
                        item.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
        ],
      ),
    );
  }

  Widget _myComments(
    AppLocalizations l10n,
    TextTheme text,
    ColorScheme scheme,
  ) {
    if (_commentsError.isNotEmpty) {
      return _errorLine(l10n, _commentsError, text, scheme);
    }
    final page = _comments;
    if (page == null) return const SizedBox.shrink();
    if (page.comments.isEmpty) {
      return Panel(
        child: Text(
          l10n.hamNoMyComments,
          style: text.bodySmall?.copyWith(color: scheme.outline),
        ),
      );
    }
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.hamTotalCount.replaceAll('%d', '${page.total}'),
            style: text.bodySmall?.copyWith(color: scheme.outline),
          ),
          for (final comment in page.comments)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.spaceSm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          comment.createTime,
                          style: text.labelSmall
                              ?.copyWith(color: scheme.outline),
                        ),
                      ),
                      if (comment.rate > 0)
                        Text(
                          '★' * comment.rate,
                          style: text.bodySmall
                              ?.copyWith(color: scheme.tertiary),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(comment.content, style: text.bodyMedium),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _errorLine(
    AppLocalizations l10n,
    String error,
    TextTheme text,
    ColorScheme scheme,
  ) =>
      Padding(
        padding: const EdgeInsets.only(bottom: AppTheme.spaceSm),
        child: Text(
          l10n.hamSectionFailed.replaceAll('%s', error),
          style: text.bodySmall?.copyWith(color: scheme.error),
        ),
      );
}
