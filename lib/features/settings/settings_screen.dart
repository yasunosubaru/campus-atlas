import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/result.dart';
import '../../core/storage/settings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../main.dart';
import '../whu_auth/account_login_screen.dart';
import '../whu_auth/whu_session.dart';
import 'location_picker.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ThemeMode _themeMode = ThemeMode.system;
  String _locale = 'zh';
  Geo _geo = Geo.fromConfig();
  bool _metric = true;
  DateTime _firstWeekStart = DateTime(2026, 2, 23);
  bool _loading = true;

  final _aiBase = TextEditingController();
  final _aiKey = TextEditingController();
  final _aiModel = TextEditingController();
  String? _aiStatus;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _aiBase.dispose();
    _aiKey.dispose();
    _aiModel.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final services = AppScope.of(context, dependOn: false);
    final results = await Future.wait([
      services.settings.themeMode(),
      services.settings.localeCode(),
      services.settings.location(),
      services.settings.metricWeather(),
      services.settings.aiEndpoint(),
      services.settings.firstWeekStart(),
    ]);
    if (!mounted) return;
    setState(() {
      _themeMode = results[0] as ThemeMode;
      _locale = results[1] as String;
      _geo = results[2] as Geo;
      _metric = results[3] as bool;
      final endpoint = results[4] as AiEndpoint;
      _aiBase.text = endpoint.baseUrl;
      _aiKey.text = endpoint.apiKey;
      _aiModel.text = endpoint.model;
      _firstWeekStart = results[5] as DateTime;
      _loading = false;
    });
  }

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickFirstWeek() async {
    final services = AppScope.of(context, dependOn: false);
    final picked = await showDatePicker(
      context: context,
      initialDate: _firstWeekStart,
      firstDate: DateTime(2015),
      lastDate: DateTime(2035),
      helpText: AppLocalizations.of(context).settingsFirstWeek,
    );
    if (picked == null || !mounted) return;
    await services.settings.setFirstWeekStart(picked);
    if (!mounted) return;
    setState(() => _firstWeekStart = picked);
    services.notifyTimetableChanged();
  }

  Future<void> _notifySettings() async {
    // Re-read everything rather than diffing: settings changes are rare and
    // this path must leave no stale field behind.
    await _load();
    if (mounted) AppScope.notifySettingsChanged(context);
  }

  Future<void> _saveAi() async {
    final services = AppScope.of(context, dependOn: false);
    await services.settings.setAiEndpoint(
      AiEndpoint(
        baseUrl: _aiBase.text.trim(),
        apiKey: _aiKey.text.trim(),
        model: _aiModel.text.trim(),
      ),
    );
    if (mounted) setState(() => _aiStatus = null);
  }

  Future<void> _testAi() async {
    final l10n = AppLocalizations.of(context);
    // Resolve dependencies before any await: using BuildContext after an
    // async gap is unsafe even with a mounted guard on the State.
    final services = AppScope.of(context, dependOn: false);
    await _saveAi();
    final result = await services.ai.checkConnection();
    if (!mounted) return;
    setState(() {
      _aiStatus =
          result is Success ? l10n.settingsAiCheckOk : l10n.aiCheckFailed;
    });
  }

  /// The account row's one-line status: not signed in, remaining minutes, or
  /// expired. The 2-hour budget is the same one the grade chain enforces.
  String _accountSubtitle(AppLocalizations l10n, WhuSession? session) {
    if (session == null) return l10n.accountSignedOut;
    final left = const Duration(hours: 2) -
        DateTime.now().difference(session.acquiredAt);
    if (left.isNegative) return l10n.accountExpired;
    return l10n.accountSignedInShort.replaceAll('%d', '${left.inMinutes}');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.settingsTitle)),
        body: const CenterLoader(),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.spaceMd,
          AppTheme.spaceSm,
          AppTheme.spaceMd,
          AppTheme.spaceXl,
        ),
        children: [
          SectionHeader(l10n.accountTitle),
          ValueListenableBuilder<WhuSession?>(
            valueListenable:
                AppScope.of(context, dependOn: false).sessionChanges,
            builder: (context, session, _) => Panel(
              child: ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(l10n.accountTitle),
                subtitle: Text(_accountSubtitle(l10n, session)),
                trailing: const Icon(Icons.chevron_right),
                contentPadding: EdgeInsets.zero,
                onTap: () => AccountLoginScreen.push(context),
              ),
            ),
          ),
          SectionHeader(l10n.settingsAppearance),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.spaceSm),
                  child: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    segments: [
                      for (final mode in ThemeMode.values)
                        ButtonSegment<ThemeMode>(
                          value: mode,
                          label: Text(switch (mode) {
                            ThemeMode.system => l10n.settingsThemeSystem,
                            ThemeMode.light => l10n.settingsThemeLight,
                            ThemeMode.dark => l10n.settingsThemeDark,
                          }),
                        ),
                    ],
                    selected: {_themeMode},
                    onSelectionChanged: (selection) async {
                      final services = AppScope.of(context, dependOn: false);
                      await services.settings.setThemeMode(selection.first);
                      await _notifySettings();
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.translate_outlined),
                  title: Text(l10n.settingsLanguage),
                  trailing: DropdownButton<String>(
                    value: _locale,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 'zh', child: Text('中文')),
                      DropdownMenuItem(value: 'en', child: Text('English')),
                    ],
                    onChanged: (v) async {
                      if (v == null) return;
                      final services = AppScope.of(context, dependOn: false);
                      await services.settings.setLocaleCode(v);
                      await _notifySettings();
                    },
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.thermostat_outlined),
                  title: Text(l10n.weatherTitle),
                  subtitle: Text(_metric ? '°C' : '°F'),
                  value: _metric,
                  onChanged: (v) async {
                    final services = AppScope.of(context, dependOn: false);
                    await services.settings.setMetricWeather(v);
                    await _notifySettings();
                  },
                ),
              ],
            ),
          ),
          SectionHeader(l10n.settingsLocation),
          Panel(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(_geo.name.isEmpty ? '—' : _geo.name),
                  subtitle: Text(
                    '${_geo.latitude.toStringAsFixed(4)}, '
                    '${_geo.longitude.toStringAsFixed(4)}',
                    style: text.bodySmall,
                  ),
                  contentPadding: EdgeInsets.zero,
                  onTap: () async {
                    // Capture before the await; see _testAi.
                    final services = AppScope.of(context, dependOn: false);
                    final picked = await showLocationPicker(context);
                    if (picked == null || !mounted) return;
                    await services.settings.setLocation(picked);
                    await _notifySettings();
                  },
                ),
              ],
            ),
          ),
          SectionHeader(l10n.settingsTimetable),
          Panel(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_month_outlined),
              title: Text(l10n.settingsFirstWeek),
              subtitle: Text(l10n.settingsFirstWeekBody),
              trailing: Text(
                _date(_firstWeekStart),
                style: text.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              onTap: _pickFirstWeek,
            ),
          ),
          SectionHeader(l10n.settingsAi),
          Panel(
            child: Column(
              children: [
                TextField(
                  controller: _aiBase,
                  decoration: InputDecoration(
                    labelText: l10n.settingsAiBase,
                    hintText: 'https://api.example.com/v1',
                  ),
                  keyboardType: TextInputType.url,
                  onChanged: (_) => setState(() => _aiStatus = null),
                ),
                const SizedBox(height: AppTheme.spaceSm),
                TextField(
                  controller: _aiKey,
                  decoration: InputDecoration(
                    labelText: l10n.settingsAiKey,
                    hintText: 'sk-…',
                  ),
                  obscureText: true,
                  onChanged: (_) => setState(() => _aiStatus = null),
                ),
                const SizedBox(height: AppTheme.spaceSm),
                TextField(
                  controller: _aiModel,
                  decoration: InputDecoration(
                    labelText: l10n.settingsAiModel,
                    hintText: 'gpt-4o-mini',
                  ),
                  onChanged: (_) => setState(() => _aiStatus = null),
                ),
                const SizedBox(height: AppTheme.spaceMd),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saveAi,
                        child: Text(l10n.save),
                      ),
                    ),
                    const SizedBox(width: AppTheme.spaceSm),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: _testAi,
                        child: Text(l10n.settingsAiCheck),
                      ),
                    ),
                  ],
                ),
                if (_aiStatus != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppTheme.spaceSm),
                    child: Text(_aiStatus!, style: text.bodySmall),
                  ),
              ],
            ),
          ),
          SectionHeader(l10n.settingsDataSources),
          Panel(
            child: Text(l10n.settingsDataSourcesBody, style: text.bodyMedium),
          ),
          SectionHeader(l10n.settingsAbout),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Campus Atlas 0.1.0', style: text.titleMedium),
                const SizedBox(height: AppTheme.spaceSm),
                Text(l10n.settingsAboutBody, style: text.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
