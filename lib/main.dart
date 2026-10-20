import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/diagnostics/crash_log.dart';
import 'core/i18n/app_localizations.dart';
import 'core/network/api_client.dart';
import 'core/storage/settings.dart';
import 'core/theme/app_theme.dart';
import 'features/agenda/agenda_repository.dart';
import 'features/ai_chat/ai_chat_repository.dart';
import 'features/campus_map/map_repository.dart';
import 'features/courses/course_repository.dart';
import 'features/grades_query/archive/grade_archive_repository.dart';
import 'features/teaching_eval/review_drafts.dart';
import 'features/timetable/timetable_repository.dart';
import 'features/weather/weather_repository.dart';
import 'features/whu_auth/whu_session.dart';
import 'shell.dart';

/// Composition root.
///
/// Dependencies are constructed once here and passed down explicitly rather
/// than via a global service locator. It costs a few constructor parameters
/// and buys the ability to build the whole app against fakes in tests.
class Services {
  Services._({
    required this.settings,
    required this.timetable,
    required this.agenda,
    required this.weather,
    required this.map,
    required this.ai,
    required this.courses,
    required this.gradeArchive,
    required this.reviewDrafts,
    required this.client,
  });

  final AppSettings settings;
  final TimetableRepository timetable;
  final AgendaRepository agenda;
  final WeatherRepository weather;
  final MapRepository map;
  final AiChatRepository ai;
  final CourseRepository courses;

  /// Grades a person has read out of the academic system, kept locally. The
  /// archive outlives the session that produced it, on purpose: the query is
  /// gated by a puzzle, so paying it once should keep answering GPA questions.
  final GradeArchiveRepository gradeArchive;

  /// Course-evaluation drafts written ahead of the timed evaluation page.
  final ReviewDraftRepository reviewDrafts;

  /// Shared HTTP transport. Exposed so a feature that needs custom headers or
  /// a raw response body — 教务 grade queries carry a `Cookie` header and must
  /// inspect the body themselves — can use the one client rather than opening
  /// its own socket pool.
  final ApiClient client;

  /// The live CAS single-sign-on session, if the person has signed in during
  /// this run. Deliberately **mutable and in-memory**:
  ///
  ///   * mutable because a sign-in can happen from any screen,
  ///   * in-memory because writing it to `shared_preferences` would put a
  ///     single-sign-on credential in a plaintext file on desktop, and the
  ///     convenience of skipping one WebView sign-in is not worth that.
  ///
  /// It is null again the next time the app starts, by design.
  WhuSession? get whuSession => _session.value;
  set whuSession(WhuSession? value) => _session.value = value;

  final ValueNotifier<WhuSession?> _session = ValueNotifier<WhuSession?>(null);

  /// Fires whenever [whuSession] changes.
  ///
  /// Needed because a sign-in can happen on a screen other than the one that
  /// shows its result: the in-app browser establishes the session, and the 教务
  /// screen has to notice. The inherited widget cannot carry that — its
  /// `updateShouldNotify` compares [Services] identity, which never changes — so
  /// a screen that cares listens here instead.
  ValueNotifier<WhuSession?> get sessionChanges => _session;

  final ValueNotifier<int> _timetableChanges = ValueNotifier<int>(0);

  /// Fires whenever stored timetable data or its week anchor changes.
  ///
  /// The import happens on the timetable tab while the home tab is already
  /// built; without this it keeps the courses and week it loaded at launch and
  /// a successful import still reads as "no courses this week".
  ValueNotifier<int> get timetableChanges => _timetableChanges;

  void notifyTimetableChanged() => _timetableChanges.value++;

  static Future<Services> create() async {
    final store = await PrefsSettingsStore.open();
    final client = await buildDefaultClient();

    final settings = AppSettings(store);
    return Services._(
      settings: settings,
      timetable: TimetableRepository(store),
      agenda: AgendaRepository(store),
      weather: WeatherRepository(client: client, settings: settings),
      map: MapRepository(client: client),
      ai: AiChatRepository(client: client, settings: settings),
      courses: CourseRepository(client: client),
      gradeArchive: GradeArchiveRepository(store),
      reviewDrafts: ReviewDraftRepository(store),
      client: client,
    );
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Installed before the first frame so an error during startup is recorded
  // too. On Windows the release build has no console, so without this a failure
  // is indistinguishable from a blank window.
  installCrashLog();
  runApp(const CampusAtlasApp());
}

/// App root. Bootstraps [Services] before the first frame so the UI never has
/// to render a "loading configuration" state.
class CampusAtlasApp extends StatefulWidget {
  const CampusAtlasApp({super.key});

  @override
  State<CampusAtlasApp> createState() => _CampusAtlasAppState();
}

class _CampusAtlasAppState extends State<CampusAtlasApp> {
  late final Future<Services> _boot;
  ThemeMode _themeMode = ThemeMode.system;
  Locale _locale = const Locale('zh');

  @override
  void initState() {
    super.initState();
    _boot = _start();
  }

  Future<Services> _start() async {
    final services = await Services.create();
    final mode = await services.settings.themeMode();
    final code = await services.settings.localeCode();
    if (mounted) {
      setState(() {
        _themeMode = mode;
        _locale = Locale(code);
      });
    }
    return services;
  }

  void _onSettingsChanged() async {
    final services = await _boot;
    final mode = await services.settings.themeMode();
    final code = await services.settings.localeCode();
    if (!mounted) return;
    setState(() {
      _themeMode = mode;
      _locale = Locale(code);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Services>(
      future: _boot,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Failed to start:\n${snapshot.error}',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          );
        }

        if (!snapshot.hasData) {
          return const MaterialApp(
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }

        return AppScope(
          services: snapshot.data!,
          onSettingsChanged: _onSettingsChanged,
          child: MaterialApp(
            title: 'Campus Atlas',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: _themeMode,
            locale: _locale,
            supportedLocales: AppLocalizations.supportedLocales,
            // The Global* delegates are required, not the Default* ones:
            // DefaultMaterialLocalizations only covers en, and our default
            // locale is zh — without these, every Material widget that needs
            // a localized string throws at build time.
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const AppShell(),
          ),
        );
      },
    );
  }
}

/// Exposes [Services] and a settings-change notifier to the widget tree.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.services,
    required this.onSettingsChanged,
    required super.child,
  });

  final Services services;
  final VoidCallback onSettingsChanged;

  static Services of(BuildContext context, {bool dependOn = true}) {
    final scope = dependOn
        ? context.dependOnInheritedWidgetOfExactType<AppScope>()
        : context.getElementForInheritedWidgetOfExactType<AppScope>()?.widget
            as AppScope?;
    assert(scope != null, 'AppScope is missing from the widget tree');
    return scope!.services;
  }

  static AppScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>();

  /// Call after any persisted setting changes so the app root can re-read
  /// theme/locale and rebuild. Reads the element directly: this is a
  /// notification, not a subscription, so it must not register a dependency.
  static void notifySettingsChanged(BuildContext context) {
    final element = context.getElementForInheritedWidgetOfExactType<AppScope>();
    final scope = element?.widget;
    if (scope is AppScope) scope.onSettingsChanged();
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      oldWidget.services != services ||
      oldWidget.onSettingsChanged != onSettingsChanged;
}

/// Builds the default [ApiClient] with the app's standard timeouts and
/// retry budget.
Future<ApiClient> buildDefaultClient() async => ApiClient();
