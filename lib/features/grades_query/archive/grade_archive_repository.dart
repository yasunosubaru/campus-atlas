import 'dart:convert';

import '../../../core/result.dart';
import '../../../core/storage/settings.dart';
import 'grade_models.dart';

/// What one merge did to the archive.
class GradeMergeResult {
  const GradeMergeResult({
    required this.added,
    required this.updated,
    required this.total,
  });

  final int added;
  final int updated;
  final int total;

  bool get changed => added > 0 || updated > 0;
}

/// Local-first storage for imported grades.
///
/// Same shape as the timetable repository and for the same reasons: a term
/// holds tens of rows, changes arrive on explicit user action (a read of the
/// grade table), and avoiding a database dependency keeps `flutter test` free
/// of platform channels. One JSON document in the key/value store is enough.
///
/// The merge rule is **replace by key**, not append: a re-read of the same term
/// — after a 补考 or a 重修 grade lands — must update the stored row rather
/// than duplicate it.
class GradeArchiveRepository {
  GradeArchiveRepository(this._store);

  final SettingsStore _store;
  static const String _key = 'grades.archive.v1';

  Future<Result<List<GradeRecord>>> load() async {
    final raw = await _store.getString(_key);
    if (raw.trim().isEmpty) return const Success(<GradeRecord>[]);

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return Failure<List<GradeRecord>>.reason(
          FailureKind.invalidData,
          message: 'Grade archive payload was not a list',
        );
      }
      final out = <GradeRecord>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        // A row that does not parse is skipped rather than failing the whole
        // archive: one corrupted entry must not hide nineteen good ones.
        final record =
            GradeRecord.fromJson(Map<String, Object?>.from(item)).dataOrNull;
        if (record != null) out.add(record);
      }
      out.sort(GradeRecord.compare);
      return Success(out);
    } catch (e) {
      return Failure<List<GradeRecord>>.reason(
        FailureKind.invalidData,
        message: 'Grade archive could not be decoded: $e',
      );
    }
  }

  /// Merges [incoming] into the archive, one row per course per term.
  ///
  /// Within a single import the last row for a key wins — a grid that lists a
  /// course twice (it happens with 重修 rows) must not count the earlier copy
  /// as an update.
  Future<Result<GradeMergeResult>> merge(List<GradeRecord> incoming) async {
    final current = await load();
    if (current is Failure<List<GradeRecord>>) {
      return Failure<GradeMergeResult>(current.failure);
    }

    final byKey = <String, GradeRecord>{
      for (final record in current.requireValue) record.key: record,
    };

    var added = 0;
    var updated = 0;
    final deduped = <String, GradeRecord>{
      for (final record in incoming) record.key: record,
    };
    for (final record in deduped.values) {
      final existing = byKey[record.key];
      if (existing == record) continue;
      if (existing == null) {
        added++;
      } else {
        updated++;
      }
      byKey[record.key] = record;
    }

    final list = byKey.values.toList()..sort(GradeRecord.compare);
    await _store.setString(
      _key,
      jsonEncode([for (final record in list) record.toJson()]),
    );
    return Success(
      GradeMergeResult(added: added, updated: updated, total: list.length),
    );
  }

  /// Removes the row with [key], answering the remaining rows.
  ///
  /// Used by the manual channel: rows a person typed are theirs to correct,
  /// while imported rows come back the next time the grade table is read and are
  /// better fixed at the source.
  Future<Result<List<GradeRecord>>> remove(String key) async {
    final current = await load();
    if (current is Failure<List<GradeRecord>>) return current;

    final remaining = [
      for (final record in current.requireValue)
        if (record.key != key) record,
    ];
    await _store.setString(
      _key,
      jsonEncode([for (final record in remaining) record.toJson()]),
    );
    return Success(remaining);
  }

  /// Removes the local copy. The school's own system is untouched, and the next
  /// read of the grade table restores the archive.
  Future<void> clear() => _store.remove(_key);
}
