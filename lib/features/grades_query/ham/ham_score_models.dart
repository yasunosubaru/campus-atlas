/// The shape of a 给分 result, from Ham's own MCP service.
///
/// ## Two shapes, both accepted
///
/// The **MCP** service answers `get_course_grade_stats` with a nested envelope
/// [V] — captured from a live call:
///
/// ```json
/// {
///   "items": [{
///     "course": {"course_idx":"数字信号处理\u001f陈小莉", "id":"7543…",
///                "instructor":"陈小莉", "instructor_list":["陈小莉"],
///                "name":"数字信号处理"},
///     "stat":   {"average":84.848, "median":87, "total":66,
///                "course_table_id":"7543…", "id":0,
///                "range":[{"from":0,"to":59,"total":1}, …]}
///   }],
///   "range_config": [{"color":"#FF5722","from":0,"to":59}, …]
/// }
/// ```
///
/// Note **`median`**, which the proto contract does not have, and note that the
/// bands carry no colour of their own — the colours come from `range_config`, one
/// entry per band, shared by every course in the answer.
///
/// The **gateway's REST** shape is flat instead
/// (`ham-gateway/internal/handlers/handlers.go`):
///
/// ```json
/// {"name":"…","instructor":"…","average":0.0,"total":0,
///  "range":[{"from":90,"to":100,"total":0,"color":"…"}]}
/// ```
///
/// Both are parsed. Supporting only the documented one would have failed against
/// the service that actually answers, which is the mistake this comment exists to
/// prevent repeating.
library;

/// One score band: how many students fell between [from] and [to].
class HamScoreBucket {
  const HamScoreBucket({
    required this.from,
    required this.to,
    required this.total,
    this.color = '',
  });

  final int from;
  final int to;

  /// Sample count in this band. Zero means nobody reported a mark here, which is
  /// different from the band not existing.
  final int total;

  /// A colour for this band. Either sent per band, or resolved from the answer's
  /// shared `range_config`.
  final String color;

  /// A copy carrying [colour] when this band has none of its own.
  HamScoreBucket withColorIfMissing(String colour) =>
      color.isNotEmpty || colour.isEmpty
          ? this
          : HamScoreBucket(from: from, to: to, total: total, color: colour);

  static HamScoreBucket? tryParse(Object? node) {
    if (node is! Map) return null;
    final from = _int(node['from']);
    final to = _int(node['to']);
    if (from == null || to == null) return null;
    return HamScoreBucket(
      from: from,
      to: to,
      total: _int(node['total']) ?? 0,
      color: '${node['color'] ?? ''}',
    );
  }

  @override
  String toString() => '$from-$to: $total';
}

/// One course, narrowed to one instructor, with its distribution.
class HamCourseScore {
  const HamCourseScore({
    required this.name,
    required this.instructor,
    required this.average,
    required this.total,
    required this.buckets,
    this.median,
    this.id = '',
    this.courseTableId = '',
  });

  final String name;
  final String instructor;

  /// The mean mark, when the service reports one. **Direction and scale are the
  /// service's**: a mark out of 100, carried through untouched rather than
  /// inverted into a "difficulty" score.
  final double? average;

  /// The median mark, when reported. Present on the MCP answer and absent from the
  /// proto, so it is optional.
  ///
  /// Worth showing next to the mean: a course whose mean is 85 and median 92 has
  /// a different shape from one where both are 85, and students care about that
  /// difference more than about the mean alone.
  final int? median;

  /// How many marks the distribution is built from. A small number is worth
  /// showing plainly — a mean of 85 from 3 people is not a fact about the course.
  final int total;

  final List<HamScoreBucket> buckets;

  /// The course's own id in Ham's database.
  final String id;

  /// The id the other tools take (`get_course_detail`, `get_course_comments`,
  /// `get_semester_grade_stats`).
  final String courseTableId;

  bool get isEmpty => total == 0 && buckets.every((b) => b.total == 0);

  /// The bucket with the most samples, or null when there is nothing to show.
  ///
  /// Computed from the data rather than from [total]: a band can legitimately
  /// exceed the reported total when the service counts differently, and scaling
  /// by the total would then draw a bar wider than its row.
  int? get busiestBucket {
    int? best;
    for (final b in buckets) {
      if (best == null || b.total > best) best = b.total;
    }
    return (best ?? 0) > 0 ? best : null;
  }

  /// Reads one item, nested (`{course, stat}`) or flat.
  static HamCourseScore? tryParse(Object? node) {
    if (node is! Map) return null;

    // The nested MCP shape puts identity under `course` and numbers under `stat`.
    final course = node['course'] is Map ? node['course'] as Map : node;
    final stat = node['stat'] is Map ? node['stat'] as Map : node;

    final name = _text(course, const ['name', 'courseName', 'course_name']);
    final instructor =
        _text(course, const ['instructor', 'instructorName', 'teacherName']);

    // A payload with neither a name nor an instructor is not a course. The
    // gateway's "no data" answer is exactly that: every field zeroed. Reading it
    // as a course would render a blank card that looks like a bug.
    if ((name ?? '').isEmpty && (instructor ?? '').isEmpty) return null;

    final rawRanges = stat['range'] ?? node['range'] ?? stat['buckets'];
    final buckets = <HamScoreBucket>[];
    if (rawRanges is List) {
      for (final r in rawRanges) {
        final b = HamScoreBucket.tryParse(r);
        if (b != null) buckets.add(b);
      }
    }

    return HamCourseScore(
      name: name ?? '',
      instructor: instructor ?? '',
      average: _double(stat['average'] ?? node['average']),
      median: _int(stat['median'] ?? node['median']),
      total: _int(stat['total'] ?? node['total']) ?? 0,
      buckets: buckets,
      id: _text(course, const ['id', 'courseId', 'course_id']) ?? '',
      courseTableId:
          _text(stat, const ['course_table_id', 'courseTableId']) ?? '',
    );
  }

  /// Pulls the list out of whatever envelope the service returned, and applies the
  /// shared band colours.
  ///
  /// Envelopes seen or plausible: a bare array, `items`, `results`, `data`, or a
  /// single flat item. An unknown envelope yields an empty list rather than an
  /// exception — the caller then reports "no data", which is the honest reading of
  /// a shape it cannot parse.
  static List<HamCourseScore> listFrom(Object? payload) {
    final out = <HamCourseScore>[];
    final rangeConfig = <String, String>{};

    void take(Object? node) {
      if (node is List) {
        for (final item in node) {
          final s = HamCourseScore.tryParse(item);
          if (s != null) out.add(s);
        }
        return;
      }
      if (node is! Map) return;

      // `range_config` travels alongside the items, not inside them.
      final cfg = node['range_config'] ?? node['rangeConfig'];
      if (cfg is List) {
        for (final c in cfg) {
          if (c is Map) {
            final from = _int(c['from']);
            final to = _int(c['to']);
            if (from != null && to != null) {
              rangeConfig['$from-$to'] = '${c['color'] ?? ''}';
            }
          }
        }
      }

      // A single item, not a list. Checked against the camelCase spellings too:
      // `instructorName` is what protobuf's JSON mapping produces, and a check
      // for `instructor` alone silently drops every such payload.
      final looksLikeOneItem = node.containsKey('course') ||
          node.containsKey('instructor') ||
          node.containsKey('instructorName') ||
          node.containsKey('courseName') ||
          node.containsKey('average');
      if (looksLikeOneItem) {
        final s = HamCourseScore.tryParse(node);
        if (s != null) out.add(s);
        return;
      }
      for (final key in const ['items', 'results', 'data', 'list', 'courses']) {
        if (node.containsKey(key)) {
          take(node[key]);
          return;
        }
      }
    }

    take(payload);

    if (rangeConfig.isEmpty) return out;
    return [
      for (final s in out)
        HamCourseScore(
          name: s.name,
          instructor: s.instructor,
          average: s.average,
          median: s.median,
          total: s.total,
          id: s.id,
          courseTableId: s.courseTableId,
          buckets: [
            for (final b in s.buckets)
              b.withColorIfMissing(rangeConfig['${b.from}-${b.to}'] ?? ''),
          ],
        ),
    ];
  }

  @override
  String toString() => 'HamCourseScore($name / $instructor · avg=$average · '
      'median=$median n=$total · ${buckets.length} bands)';
}

String? _text(Map<dynamic, dynamic> node, List<String> keys) {
  for (final k in keys) {
    final v = node[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? _double(Object? v) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}
