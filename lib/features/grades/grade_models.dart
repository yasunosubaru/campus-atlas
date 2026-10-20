/// Grade-query models for the 教务 system.
///
/// **Evidence class:** every documented field below is `[D]` — read out of
/// `jwgl`'s own `cxDgXscj.js` by the earlier `ham-win` session, which was able
/// to read the page's own script because `/js/**` needs no session. This
/// project did **not** capture a live grade response: the endpoint is behind
/// CAS and reaching it needs an interactive sign-in. So the shapes here are
/// modelled on what jQuery Grid emits, and the parser is built to cope with
/// the variants rather than to pin one down. See
/// the 2026-10-14 capture of that grid (kept outside this repository).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;

import '../../core/network/body_shape.dart';
import '../../core/result.dart';

// Re-exported so existing importers of this library keep working; the
// predicates themselves live in core/network/body_shape.dart and are shared
// with the grade-query feature.
export '../../core/network/body_shape.dart';

/// Whether a JSON body is an error envelope rather than data.
///
/// Only the authentication case is detected here, because only it can be
/// recognised without inventing an error taxonomy this project never saw.
/// Any other `{"status":..}` payload falls through to the parser, which is the
/// safer direction: a misclassified auth error would send the user back to
/// sign in when the session was fine.
bool isJsonErrorBody(String body) {
  final t = body.trimLeft();
  if (!t.startsWith('{')) return false;
  return t.contains('"status":401') ||
      t.contains('"status": 401') ||
      t.contains('"code":"UNAUTHORIZED"') ||
      t.contains('"code": "UNAUTHORIZED"');
}

/// One grade row.
///
/// [Documented] fields are the `[D]`-verified column names. Everything else the
/// page returns is preserved verbatim in [raw] rather than being shaped into
/// fields this project has not seen — so a payload can arrive with columns we
/// do not know about and nothing is lost or mis-typed.
@immutable
class GradeRecord {
  const GradeRecord({
    required this.name,
    required this.raw,
    this.courseCode = '',
    this.teacher = '',
    this.department = '',
    this.courseNature = '',
    this.credits,
    this.score,
    this.scoreText = '',
  });

  /// `kcmc` [D] 课程名称.
  final String name;

  /// `kch` if present — course code. Not among the documented names, so
  /// extracted opportunistically from [raw].
  final String courseCode;

  /// `jsxm` [D] 教师姓名.
  final String teacher;

  /// `kkbmmc` [D] 上课部门名称.
  final String department;

  /// `kcxzmc` [D] 课程性质名称 (必修/选修...).
  final String courseNature;

  /// `xf` [D] 学分. Null when absent or unreadable rather than 0, so that
  /// "no credits recorded" cannot silently drag an average down.
  final double? credits;

  /// Numeric score, parsed out of `bfzcj` when it parses.
  ///
  /// `bfzcj` [D] is **not** reliably numeric: this system also carries
  /// non-numeric outcomes (免修 / 缺考 / 合格 / 不及格). [score] is null in
  /// exactly those cases and [scoreText] holds the original.
  final double? score;

  /// The original `bfzcj` display value, always present.
  final String scoreText;

  /// Every field from the payload, unmodified. Use it for diagnostics and for
  /// columns this project has not catalogued.
  final Map<String, Object?> raw;

  bool get hasNumericScore => score != null;

  /// Whether the row identifies a course at all.
  bool get isValid => name.isNotEmpty;

  // --------------------------------------------------------------- parsing

  /// Reads one row. Returns null when there is no course name — a row that
  /// names nothing cannot be shown as a grade.
  static GradeRecord? tryParse(Object? source) {
    if (source is! Map<String, Object?>) return null;
    final raw = Map<String, Object?>.from(source);

    final name = _text(raw, ['kcmc', 'courseName', 'name']);
    if (name == null || name.isEmpty) return null;

    final scoreText = _text(raw, ['bfzcj', 'score', 'grade']) ?? '';
    final parsedScore = _toDoubleOrNull(scoreText);

    return GradeRecord(
      name: name,
      courseCode: _text(raw, ['kch', 'code']) ?? '',
      teacher: _text(raw, ['jsxm', 'teacherName']) ?? '',
      department: _text(raw, ['kkbmmc', 'department']) ?? '',
      courseNature: _text(raw, ['kcxzmc', 'courseNature']) ?? '',
      credits: _toDoubleOrNull(_text(raw, ['xf', 'credit'])),
      score: parsedScore,
      scoreText: scoreText,
      raw: raw,
    );
  }

  /// First usable text value among [keys], trimmed. `null` when none yields
  /// anything — so that "absent" and "empty string" stay distinguishable.
  static String? _text(Map<String, Object?> row, List<String> keys) {
    for (final k in keys) {
      final v = row[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
      // Present-but-empty on the first matching key: keep looking rather than
      // reporting an empty string as if it were the answer.
    }
    return null;
  }

  /// Parses a number leniently: tolerates trims, decimal points, and full-width
  /// digits/periods common in Chinese numeric input. Null when it is not a
  /// number at all — never a zero, because a zero score and an unreadable score
  /// must not be confused.
  static double? _toDoubleOrNull(String? s) {
    if (s == null) return null;
    final normalised = s.trim().replaceAll('．', '.').replaceAll('。', '.');
    if (normalised.isEmpty) return null;
    // Full-width digits ０-９ -> 0-9
    final folded = normalised.runes
        .map((r) => (r >= 0xFF10 && r <= 0xFF19) ? r - 0xFEE0 : r)
        .map(String.fromCharCode)
        .join();
    return double.tryParse(folded);
  }

  @visibleForTesting
  static double? parseScore(String? raw) => _toDoubleOrNull(raw);

  @override
  String toString() =>
      'GradeRecord($name ${scoreText.isEmpty ? '—' : scoreText})';
}

/// One term's worth of grades.
@immutable
class GradeSheet {
  const GradeSheet({
    required this.year,
    required this.xqm,
    required this.records,
    this.total = 0,
    this.envelope = '',
  });

  /// Academic year label exactly as sent in `xnm` (e.g. `"2025-2026"`).
  final String year;

  /// The raw `xqm` term code as sent.
  ///
  /// Kept raw on purpose: **the mapping from `xqm` to the app's term enum is
  /// not established.** The earlier session found candidate codes and could not
  /// pin them authoritatively. See `WhuTermXqmResolver`.
  final String xqm;

  final List<GradeRecord> records;

  /// The server's declared row count, which may exceed [records] if the page
  /// was short. Zero when the envelope carried none.
  final int total;

  /// Which response shape was matched — `'rows'`, `'items'`, `'data'`,
  /// `'array'`, or `''` when nothing was recognised. Surfaced so an unexpected
  /// envelope is visible instead of looking like an empty term.
  final String envelope;

  bool get isEmpty => records.isEmpty;

  int get returnedCount => records.length;

  /// Whether the server claims more rows than we read, i.e. the parse was
  /// probably incomplete rather than the term being empty.
  bool get truncated => total > returnedCount;

  /// Records that carry a numeric score.
  Iterable<GradeRecord> get numeric =>
      records.where((r) => r.score != null).toList(growable: false);

  /// Sum of credits on records that carry one.
  double get creditTotal =>
      records.fold(0.0, (sum, r) => sum + (r.credits ?? 0.0));

  /// Credit-weighted mean of the numeric scores.
  ///
  /// This is plain arithmetic and well-defined, unlike a GPA conversion:
  /// **no 4.0/5.0 grade-point table for this university is established
  /// anywhere in this project**, so none is provided. Inventing one would
  /// produce an official-looking number nobody could check.
  ///
  /// Null when there is nothing to average — a real absence, not a zero.
  double? weightedMean() {
    double sum = 0, weight = 0;
    for (final r in records) {
      final s = r.score;
      if (s == null) continue;
      final w = r.credits ?? 0.0;
      if (w <= 0) continue;
      sum += s * w;
      weight += w;
    }
    if (weight > 0) return sum / weight;

    // Fall back to an unweighted mean when no credits were recorded, rather
    // than reporting null for a term that plainly has scores.
    final plain = numeric;
    if (plain.isEmpty) return null;
    return plain.fold(0.0, (a, r) => a + r.score!) / plain.length;
  }

  @visibleForTesting
  static List<GradeRecord> recordsFrom(Map<String, Object?> payload) =>
      _extractRows(payload)
          .rows
          .map(GradeRecord.tryParse)
          .nonNulls
          .toList(growable: false);
}

/// Pulls the row array out of a payload.
///
/// **[V] The envelope is now captured**, from a live jqGrid query on the same
/// system, so this no longer guesses. The body is:
///
/// ```json
/// {"currentPage":1,"currentResult":0,"entityOrField":false,"items":[],
///  "limit":15,"offset":0,"pageNo":0,"pageSize":15,"showCount":15,
///  "sortName":" ","sortOrder":"asc","sorts":[],
///  "totalCount":0,"totalPage":0,"totalResult":0}
/// ```
///
/// **`items` is the rows array**, and the server's declared row count is
/// `totalResult` (`totalCount` carries it too). That settles two things an
/// earlier version flagged as unknowable without a session: the row key, and the
/// pagination parameter names — `pageNo`, `pageSize`, `limit`, `offset`,
/// `sortName`, `sortOrder` — which are what a caller needs to page rather than
/// guess.
///
/// The other keys are still accepted, and `envelope` still reports which matched,
/// so a differently-configured deployment shows up as an empty sheet *labelled*
/// empty rather than one that quietly looks like "you have no grades".
({List<Object?> rows, String envelope}) _extractRows(
    Map<String, Object?> payload) {
  // `items` first: it is the key this system was observed to use.
  for (final key in const ['items', 'rows', 'data', 'list', 'records']) {
    final v = payload[key];
    if (v is List) return (rows: v, envelope: key);
  }
  // Some endpoints wrap the array one level deeper under these names.
  for (final key in const ['results', 'result']) {
    final v = payload[key];
    if (v is Map<String, Object?>) {
      for (final inner in const ['items', 'rows', 'data', 'list']) {
        final w = v[inner];
        if (w is List) return (rows: w, envelope: '$key.$inner');
      }
    }
  }
  return (rows: const <Object?>[], envelope: '');
}

/// Parses a whole response body.
Result<GradeSheet> parseGradeBody(
  String body, {
  required String year,
  required String xqm,
}) {
  final trimmed = body.trimLeft();

  if (trimmed.isEmpty) {
    return Failure<GradeSheet>.reason(
      FailureKind.protocol,
      message: 'Empty response body',
      endpoint: 'cjcx_cxDgXscj',
    );
  }

  // Cheap shape check first. The sign-in page is the common failure, and
  // JSON-decoding a full HTML document only to discover it is not JSON is
  // work worth skipping — but this covers *only* HTML, so a valid JSON
  // document with an unexpected root still reaches the decoder.
  if (!looksLikeJson(trimmed) && looksLikeHtml(trimmed)) {
    return Failure<GradeSheet>.reason(
      FailureKind.unauthorized,
      message: 'The academic system returned an HTML page instead of data — '
          'this is almost certainly the sign-in page, so the session has expired',
      endpoint: 'cjcx_cxDgXscj',
    );
  }

  final decoded = tryDecodeJson(trimmed);
  if (decoded == null) {
    // Two genuinely different failures wear the same symptom. A body that
    // *looked* like JSON but would not decode is a truncated or corrupt
    // payload (`invalidData`); a body that never resembled JSON is the wrong
    // thing arriving entirely (`protocol`). The messages deliberately carry no
    // body fragment — anything shown to the user must not echo a response
    // verbatim, however harmless it looks.
    return looksLikeJson(trimmed)
        ? Failure<GradeSheet>.reason(
            FailureKind.invalidData,
            message:
                'The response was cut short or corrupt, so it could not be read',
            endpoint: 'cjcx_cxDgXscj',
          )
        : Failure<GradeSheet>.reason(
            FailureKind.protocol,
            message: 'Response was neither JSON nor HTML, so it cannot be read',
            endpoint: 'cjcx_cxDgXscj',
          );
  }

  // Checked after decoding so an auth envelope is caught before it can be
  // mistaken for a well-formed payload that merely has no rows.
  if (isJsonErrorBody(trimmed)) {
    return Failure<GradeSheet>.reason(
      FailureKind.unauthorized,
      message: 'The academic system rejected the query',
      endpoint: 'cjcx_cxDgXscj',
    );
  }

  final List<Object?> rows;
  final String envelope;
  if (decoded is List) {
    rows = decoded;
    envelope = 'array';
  } else if (decoded is Map<String, Object?>) {
    final found = _extractRows(decoded);
    rows = found.rows;
    envelope = found.envelope;
  } else {
    return Failure<GradeSheet>.reason(
      FailureKind.invalidData,
      message: 'Unexpected JSON root of type ${decoded.runtimeType}',
      endpoint: 'cjcx_cxDgXscj',
    );
  }

  final records =
      rows.map(GradeRecord.tryParse).nonNulls.toList(growable: false);

  // `totalResult` is the field this system was observed to use for the declared
  // row count; `totalCount` carries it as well. The others are kept because a
  // differently-configured jqGrid names it `total` or `records`.
  final declaredTotal = decoded is Map<String, Object?>
      ? _asInt(decoded['totalResult'] ??
          decoded['totalCount'] ??
          decoded['total'] ??
          decoded['records'])
      : records.length;

  return Success(
    GradeSheet(
      year: year,
      xqm: xqm,
      records: records,
      total: declaredTotal ?? records.length,
      envelope: envelope,
    ),
  );
}

/// Decodes JSON without throwing.
///
/// Returns null on any malformed input. Kept as a separate choke point so that
/// *every* failure path out of this feature converges on a typed [Result]
/// rather than an exception crossing a repository boundary.
Object? tryDecodeJson(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
