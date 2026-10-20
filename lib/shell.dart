import 'package:flutter/material.dart';

import 'core/i18n/app_localizations.dart';
import 'features/agenda/agenda_screen.dart';
import 'features/ai_chat/ai_screen.dart';
import 'features/campus_map/map_screen.dart';
import 'features/courses/course_search_screen.dart';
import 'features/grades_query/archive/academic_status_screen.dart';
import 'features/grades_query/ham/ham_grades_screen.dart';
import 'features/grades_query/jwgl/jwgl_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/teaching_eval/review_drafts_screen.dart';
import 'features/teaching_eval/teaching_eval_screen.dart';
import 'features/timetable/timetable_screen.dart';
import 'features/weather/weather_screen.dart';
import 'home_screen.dart';

/// Bottom navigation shell.
///
/// Screens are kept alive in an [IndexedStack] so switching tabs does not
/// throw away scroll position or re-trigger a network request the user just
/// paid for on a mobile connection.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final destinations = [
      (Icons.home_outlined, Icons.home, l10n.navHome, const HomeScreen()),
      (
        Icons.wb_sunny_outlined,
        Icons.wb_sunny,
        l10n.navWeather,
        const WeatherScreen(),
      ),
      (
        Icons.calendar_month_outlined,
        Icons.calendar_month,
        l10n.navTimetable,
        const TimetableScreen(),
      ),
      (
        Icons.checklist_outlined,
        Icons.checklist,
        l10n.navAgenda,
        const AgendaScreen(),
      ),
      (Icons.explore_outlined, Icons.explore, l10n.navMore, const MoreScreen()),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [for (final d in destinations) d.$4],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in destinations)
            NavigationDestination(
              icon: Icon(d.$1),
              selectedIcon: Icon(d.$2),
              label: d.$3,
            ),
        ],
      ),
    );
  }
}

/// Secondary destinations that do not warrant a permanent tab.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.navMore)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Tile(
            icon: Icons.school_outlined,
            iconColor: scheme.primary,
            title: l10n.coursesTitle,
            subtitle: l10n.coursesSearchHint,
            onTap: () => _push(context, const CourseSearchScreen()),
          ),
          const SizedBox(height: 8),
          _Tile(
            icon: Icons.query_stats_outlined,
            iconColor: scheme.primary,
            title: l10n.gqTitle,
            // Points at the Ham-backed screen: that is the one that can actually
            // return data. The earlier screen queried a third-party backend whose
            // `offerings` dataset is empty for every course tested, so it could
            // only ever render "no data".
            subtitle: l10n.hamIntro,
            onTap: () => _push(context, const HamGradesScreen()),
          ),
          const SizedBox(height: 8),
          // Deliberately no separate 成绩 tile.
          //
          // Grades are one of the academic system's pages, not a feature of their
          // own: the same sign-in opens them, and the same anti-bot gate guards
          // them. Two tiles led to two different screens for one thing — one of
          // which could only ever fail on the captcha. The 正方教务 entry below is
          // the single way in.
          _Tile(
            icon: Icons.forum_outlined,
            iconColor: scheme.outline,
            title: l10n.evalTitle,
            subtitle: l10n.evalEvidenceNote,
            onTap: () => _push(context, const TeachingEvalScreen()),
          ),
          const SizedBox(height: 8),
          _Tile(
            icon: Icons.rate_review_outlined,
            iconColor: scheme.secondary,
            title: l10n.draftsTitle,
            subtitle: l10n.draftsIntro,
            onTap: () => _push(context, const ReviewDraftsScreen()),
          ),
          const SizedBox(height: 8),
          _Tile(
            icon: Icons.school_outlined,
            iconColor: scheme.tertiary,
            title: l10n.jwTitle,
            subtitle: l10n.jwTileSubtitle,
            onTap: () => _push(context, const JwglScreen()),
          ),
          const SizedBox(height: 8),
          _Tile(
            icon: Icons.workspace_premium_outlined,
            iconColor: scheme.secondary,
            title: l10n.statusTitle,
            subtitle: l10n.statusIntro,
            onTap: () => _push(context, const AcademicStatusScreen()),
          ),
          const SizedBox(height: 8),
          _Tile(
            icon: Icons.map_outlined,
            iconColor: scheme.secondary,
            title: l10n.mapTitle,
            subtitle: l10n.mapHint,
            onTap: () => _push(context, const MapScreen()),
          ),
          const SizedBox(height: 8),
          _Tile(
            icon: Icons.forum_outlined,
            iconColor: scheme.tertiary,
            title: l10n.aiTitle,
            subtitle: l10n.aiNotConfiguredBody,
            onTap: () => _push(context, const AiScreen()),
          ),
          const SizedBox(height: 8),
          _Tile(
            icon: Icons.settings_outlined,
            iconColor: scheme.secondary,
            title: l10n.settingsTitle,
            subtitle: l10n.settingsAboutBody,
            onTap: () => _push(context, const SettingsScreen()),
          ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: iconColor.withValues(alpha: 0.14),
          child: Icon(icon, color: iconColor),
        ),
        title: Text(title, style: text.titleMedium),
        subtitle: Text(
          subtitle,
          style: text.bodySmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
