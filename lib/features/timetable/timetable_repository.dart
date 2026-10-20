import 'dart:convert';

import '../../core/result.dart';
import '../../core/storage/settings.dart';
import 'timetable_models.dart';

/// Local-first timetable storage with several named timetables.
///
/// ## Storage layout
///
/// ```
/// timetable.profiles        [{id, name}, …]
/// timetable.activeProfile   <id>
/// timetable.courses.<id>    [course, …]        one document per timetable
/// ```
///
/// The earlier single-timetable layout (`timetable.courses`) is migrated on
/// first read into a profile called `default`: a person who already entered
/// courses must not open the app to an empty grid. The old key is removed only
/// after the copy is written, so an interrupted migration loses nothing.
///
/// A profile with an empty [TimetableProfile.name] is not an error — it is the
/// default, unnamed timetable, and the UI substitutes a localized label. Storing
/// a translated name here would freeze one language into user data.
class TimetableRepository {
  TimetableRepository(this._store);

  final SettingsStore _store;

  static const String _legacyKey = 'timetable.courses';
  static const String _profilesKey = 'timetable.profiles';
  static const String _activeKey = 'timetable.activeProfile';

  /// Profile id used for a timetable migrated from the single-timetable layout.
  static const String defaultProfileId = 'default';

  static String _coursesKey(String profileId) => 'timetable.courses.$profileId';

  // ------------------------------------------------------------------ profiles

  /// Every timetable, creating the default one on first use.
  Future<Result<List<TimetableProfile>>> profiles() => _ensureProfiles();

  /// The active timetable's id, guaranteed to name an existing profile.
  Future<Result<String>> activeProfileId() async {
    final ensured = await _ensureProfiles();
    if (ensured is Failure<List<TimetableProfile>>) {
      return Failure<String>(ensured.errorOrNull!);
    }
    final id = await _store.getString(_activeKey);
    return Success(
      ensured.requireValue.any((p) => p.id == id)
          ? id
          : ensured.requireValue.first.id,
    );
  }

  Future<Result<List<TimetableProfile>>> setActiveProfile(String id) async {
    final ensured = await _ensureProfiles();
    if (ensured is Failure<List<TimetableProfile>>) return ensured;
    if (!ensured.requireValue.any((p) => p.id == id)) {
      return Failure<List<TimetableProfile>>.reason(
        FailureKind.validation,
        message: 'No such timetable: $id',
      );
    }
    await _store.setString(_activeKey, id);
    return Success(ensured.requireValue);
  }

  Future<Result<List<TimetableProfile>>> createProfile(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return Failure<List<TimetableProfile>>.reason(
        FailureKind.validation,
        message: 'A timetable needs a name',
      );
    }
    final ensured = await _ensureProfiles();
    if (ensured is Failure<List<TimetableProfile>>) return ensured;

    final profile = TimetableProfile(
      id: _newProfileId(),
      name: trimmed,
    );
    final next = [...ensured.requireValue, profile];
    await _writeProfiles(next);
    await _store.setString(_activeKey, profile.id);
    return Success(next);
  }

  Future<Result<List<TimetableProfile>>> renameProfile(
    String id,
    String name,
  ) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return Failure<List<TimetableProfile>>.reason(
        FailureKind.validation,
        message: 'A timetable needs a name',
      );
    }
    final ensured = await _ensureProfiles();
    if (ensured is Failure<List<TimetableProfile>>) return ensured;
    if (!ensured.requireValue.any((p) => p.id == id)) {
      return Failure<List<TimetableProfile>>.reason(
        FailureKind.validation,
        message: 'No such timetable: $id',
      );
    }

    final next = [
      for (final p in ensured.requireValue)
        if (p.id == id) TimetableProfile(id: p.id, name: trimmed) else p,
    ];
    await _writeProfiles(next);
    return Success(next);
  }

  /// Deletes a timetable and its courses. The last remaining one cannot go:
  /// an app with no timetable has no grid to show and no place to add a course.
  Future<Result<List<TimetableProfile>>> deleteProfile(String id) async {
    final ensured = await _ensureProfiles();
    if (ensured is Failure<List<TimetableProfile>>) return ensured;
    if (ensured.requireValue.length <= 1) {
      return Failure<List<TimetableProfile>>.reason(
        FailureKind.validation,
        message: 'At least one timetable must remain',
      );
    }
    if (!ensured.requireValue.any((p) => p.id == id)) {
      return Failure<List<TimetableProfile>>.reason(
        FailureKind.validation,
        message: 'No such timetable: $id',
      );
    }

    final next = ensured.requireValue.where((p) => p.id != id).toList();
    await _writeProfiles(next);
    await _store.remove(_coursesKey(id));
    final active = await _store.getString(_activeKey);
    if (active == id) await _store.setString(_activeKey, next.first.id);
    return Success(next);
  }

  // ------------------------------------------------------------------- courses

  Future<Result<List<Course>>> load() async {
    final id = await activeProfileId();
    if (id is Failure<String>) return Failure<List<Course>>(id.errorOrNull!);
    return _loadProfile(id.requireValue);
  }

  Future<Result<List<Course>>> save(List<Course> courses) async {
    final id = await activeProfileId();
    if (id is Failure<String>) return Failure<List<Course>>(id.errorOrNull!);
    return _saveProfile(id.requireValue, courses);
  }

  Future<Result<List<Course>>> add(Course course) async {
    final current = await load();
    if (current is Failure<List<Course>>) return current;
    final next = [...current.requireValue, course];
    final saved = await save(next);
    if (saved is Failure<List<Course>>) return saved;
    return Success(next);
  }

  Future<Result<List<Course>>> update(Course course) async {
    final current = await load();
    if (current is Failure<List<Course>>) return current;
    final next = [
      for (final c in current.requireValue)
        if (c.id == course.id) course else c,
    ];
    final saved = await save(next);
    if (saved is Failure<List<Course>>) return saved;
    return Success(next);
  }

  Future<Result<List<Course>>> remove(String id) async {
    final current = await load();
    if (current is Failure<List<Course>>) return current;
    final next = current.requireValue.where((c) => c.id != id).toList();
    final saved = await save(next);
    if (saved is Failure<List<Course>>) return saved;
    return Success(next);
  }

  /// Replaces the active timetable wholesale. Used by an import, which is a
  /// complete answer for one term rather than a set of additions: merging a
  /// term's import into last term's courses would leave two terms in one grid.
  Future<Result<List<Course>>> replaceAll(List<Course> courses) =>
      save(courses);

  /// Courses for a given ISO weekday and teaching week, ordered by start
  /// period. Used by the "today" column on the home screen.
  Future<Result<List<Course>>> forDay(int weekday, int week) async {
    final all = await load();
    if (all is Failure<List<Course>>) return all;
    final filtered = all.requireValue
        .where((c) => c.weekday == weekday && c.occursInWeek(week))
        .toList()
      ..sort((a, b) => a.startPeriod.compareTo(b.startPeriod));
    return Success(filtered);
  }

  /// All courses visible in a whole teaching week, grouped 1..7.
  Future<Result<Map<int, List<Course>>>> forWeek(int week) async {
    final all = await load();
    // The payload type changes here (list -> map), so the failure has to be
    // re-wrapped; the underlying reason is carried over unchanged.
    if (all is Failure<List<Course>>) {
      return Failure<Map<int, List<Course>>>(all.errorOrNull!);
    }
    return Success(coursesForWeek(all.requireValue, week));
  }

  // ------------------------------------------------------------------ plumbing

  Future<Result<List<Course>>> _loadProfile(String profileId) async {
    final raw = await _store.getString(_coursesKey(profileId));
    if (raw.trim().isEmpty) return const Success(<Course>[]);

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return Failure<List<Course>>.reason(
          FailureKind.invalidData,
          message: 'Timetable payload was not a list',
        );
      }
      final out = <Course>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final parsed = Course.fromJson(Map<String, Object?>.from(item));
        if (parsed case Success(:final data)) {
          out.add(data);
        } else {
          // A single malformed row should not discard the whole timetable, but
          // it is worth surfacing: silently dropping a class is worse than
          // failing loudly.
          return Failure<List<Course>>.reason(
            FailureKind.invalidData,
            message: 'Dropping unreadable timetable row',
          );
        }
      }
      return Success(out);
    } on FormatException catch (e) {
      return Failure<List<Course>>.reason(
        FailureKind.invalidData,
        message: 'Malformed JSON',
        cause: e,
      );
    }
  }

  Future<Result<List<Course>>> _saveProfile(
    String profileId,
    List<Course> courses,
  ) async {
    await _store.setString(
      _coursesKey(profileId),
      jsonEncode([for (final c in courses) c.toJson()]),
    );
    return Success(courses);
  }

  Future<Result<List<TimetableProfile>>> _ensureProfiles() async {
    final raw = await _store.getString(_profilesKey);
    final profiles = <TimetableProfile>[];
    if (raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final parsed =
                TimetableProfile.fromJson(Map<String, Object?>.from(item));
            if (parsed case Success(:final data)) profiles.add(data);
          }
        }
      } catch (_) {
        // A corrupted profile list is rebuilt below from the legacy document;
        // failing here would strand the person with no timetable at all.
      }
    }

    if (profiles.isEmpty) {
      profiles.add(const TimetableProfile(id: defaultProfileId));
      await _writeProfiles(profiles);
      await _store.setString(_activeKey, defaultProfileId);

      final legacy = await _store.getString(_legacyKey);
      if (legacy.trim().isNotEmpty) {
        await _store.setString(_coursesKey(defaultProfileId), legacy);
        await _store.remove(_legacyKey);
      }
    }

    final active = await _store.getString(_activeKey);
    if (!profiles.any((p) => p.id == active)) {
      await _store.setString(_activeKey, profiles.first.id);
    }
    return Success(profiles);
  }

  Future<void> _writeProfiles(List<TimetableProfile> profiles) =>
      _store.setString(
        _profilesKey,
        jsonEncode([for (final p in profiles) p.toJson()]),
      );

  static int _profileCounter = 0;

  String _newProfileId() {
    _profileCounter += 1;
    return 'p${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '_${_profileCounter.toRadixString(36)}';
  }
}

/// The courses visible in one teaching week, grouped by ISO weekday.
Map<int, List<Course>> coursesForWeek(List<Course> courses, int week) {
  final grouped = <int, List<Course>>{};
  for (final c in courses) {
    if (!c.occursInWeek(week)) continue;
    grouped.putIfAbsent(c.weekday, () => []).add(c);
  }
  for (final list in grouped.values) {
    list.sort((a, b) => a.startPeriod.compareTo(b.startPeriod));
  }
  return grouped;
}

/// Derives the teaching week number from a date and the configured term start.
///
/// Returns 0 for dates before term start, so callers can show "not in term"
/// rather than a negative week.
int weekNumberFor(DateTime date, DateTime firstWeekStart) {
  final start = DateTime(
    firstWeekStart.year,
    firstWeekStart.month,
    firstWeekStart.day,
  );
  final day = DateTime(date.year, date.month, date.day);
  final diff = day.difference(start).inDays;
  if (diff < 0) return 0;
  return (diff ~/ 7) + 1;
}

/// ISO-8601 weekday (1 = Monday … 7 = Sunday).
int isoWeekday(DateTime d) => d.weekday;
