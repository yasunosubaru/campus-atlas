/// Models for Ham's account-level read tools.
///
/// The shapes below were captured from the live service on 2026-10-20 with the
/// user's own token, and they differ from the course-statistics payloads in
/// `ham_score_models.dart`:
///
/// ```json
/// get_user_info            {"avatar_url":"…","nickname":"…","user_id":"…"}
/// get_course_comments      {"comments":[{"author":"…","content":"…","create_time":"…",
///                                        "id":1,"like_total":0,"rate":5}],"total":8}
/// get_semester_grade_stats {"course":{…},"stat":{"average":…,"median":…,"total":…,
///                                               "year":2025,"semester":1,"range":[…]},
///                           "range_config":[…]}
/// get_score_rank           {"rank_items":[…],"total":0}
/// get_course_want_list     {"items":[…],"total":0}
/// get_my_comments          {"comments":[…],"total":0}
/// ```
///
/// `rank_items` and `items` were **empty for the account used to capture this**,
/// so their per-item shape is not established. They are therefore parsed into
/// [HamLooseRecord] — a best-effort title/subtitle plus the untouched map — rather
/// than into a model that would claim to know fields nobody has seen.
library;

import 'ham_score_models.dart';

/// The authenticated user's profile.
class HamUserInfo {
  const HamUserInfo({
    required this.nickname,
    this.avatarUrl = '',
    this.userId = '',
  });

  final String nickname;
  final String avatarUrl;

  /// Ham's own user id. Kept but never shown: it is an account identifier, not
  /// something a screen needs to display.
  final String userId;

  static HamUserInfo? tryParse(Object? node) {
    if (node is! Map) return null;
    final nickname = _text(node, const ['nickname', 'name', 'display_name']);
    if (nickname == null) return null;
    return HamUserInfo(
      nickname: nickname,
      avatarUrl: _text(node, const ['avatar_url', 'avatarUrl', 'avatar']) ?? '',
      userId: _text(node, const ['user_id', 'userId', 'id']) ?? '',
    );
  }
}

/// One comment on a course (or one the user wrote).
class HamComment {
  const HamComment({
    required this.id,
    required this.author,
    required this.content,
    required this.rate,
    required this.likeTotal,
    required this.createTime,
  });

  final int id;
  final String author;
  final String content;

  /// 1–5, or 0 when the comment carries no rating.
  final int rate;
  final int likeTotal;
  final String createTime;

  static HamComment? tryParse(Object? node) {
    if (node is! Map) return null;
    final content = _text(node, const ['content', 'text', 'body']);
    if (content == null) return null;
    return HamComment(
      id: _int(node['id']) ?? 0,
      author: _text(node, const ['author', 'nickname', 'user']) ?? '',
      content: content,
      rate: (_int(node['rate']) ?? 0).clamp(0, 5),
      likeTotal: _int(node['like_total'] ?? node['likeTotal']) ?? 0,
      createTime:
          _text(node, const ['create_time', 'createTime', 'created_at']) ?? '',
    );
  }
}

/// One page of comments plus the paging signal.
class HamCommentPage {
  const HamCommentPage({
    required this.comments,
    required this.total,
    this.nextCursor,
  });

  final List<HamComment> comments;

  /// How many comments exist in total, not just on this page.
  final int total;
  final String? nextCursor;

  static HamCommentPage from(Object? payload) {
    final map = payload is Map ? payload : const <String, Object?>{};
    final raw = map['comments'] ?? map['items'] ?? map['data'];
    final comments = <HamComment>[];
    if (raw is List) {
      for (final node in raw) {
        final comment = HamComment.tryParse(node);
        if (comment != null) comments.add(comment);
      }
    }
    final next = map['next_cursor'] ?? map['nextCursor'];
    return HamCommentPage(
      comments: comments,
      total: _int(map['total']) ?? comments.length,
      nextCursor: next is String && next.isNotEmpty ? next : null,
    );
  }
}

/// One course's statistics for one term.
class HamSemesterStat {
  const HamSemesterStat({
    required this.course,
    required this.year,
    required this.semester,
  });

  final HamCourseScore course;
  final int year;
  final int semester;

  static HamSemesterStat? tryParse(Object? node) {
    final score = HamCourseScore.tryParse(node);
    if (score == null) return null;
    final map = node is Map ? node : const <String, Object?>{};
    final stat = map['stat'] is Map ? map['stat'] as Map : map;
    final year = _int(stat['year']);
    final semester = _int(stat['semester']);
    if (year == null || semester == null) return null;
    return HamSemesterStat(
      course: score,
      year: year,
      semester: semester,
    );
  }
}

/// A best-effort view of an item whose shape has not been captured.
///
/// [raw] keeps the untouched map so a future capture can replace this with a real
/// model instead of guessing here.
class HamLooseRecord {
  const HamLooseRecord({
    required this.title,
    required this.subtitle,
    required this.raw,
  });

  final String title;
  final String subtitle;
  final Map<String, Object?> raw;

  static HamLooseRecord from(Object? node) {
    final map =
        node is Map ? Map<String, Object?>.from(node) : <String, Object?>{};
    final title = _pick(map, const [
      'name',
      'course_name',
      'courseName',
      'title',
      'course',
      'instructor',
      'teacher',
      'author',
      'nickname',
    ]);
    final subtitle = _pick(map, const [
      'instructor',
      'teacher',
      'term',
      'semester',
      'year',
      'created_at',
      'create_time',
      'content',
    ]);
    return HamLooseRecord(
      title: title ?? '',
      subtitle: subtitle == title ? '' : (subtitle ?? ''),
      raw: map,
    );
  }

  static String? _pick(Map<String, Object?> map, List<String> keys) {
    for (final key in keys) {
      final value = _display(map[key]);
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  static String? _display(Object? value) {
    if (value is String) return value;
    if (value is num) return '$value';
    if (value is Map) {
      for (final key in const [
        'name',
        'course_name',
        'courseName',
        'title',
        'instructor',
        'label',
      ]) {
        final nested = _display(value[key]);
        if (nested != null && nested.trim().isNotEmpty) return nested;
      }
    }
    return null;
  }
}

/// A `{items, total}` or `{rank_items, total}` envelope.
class HamLooseSection {
  const HamLooseSection({required this.items, required this.total});

  final List<HamLooseRecord> items;
  final int total;

  static HamLooseSection from(
    Object? payload, {
    List<String> itemKeys = const ['items'],
  }) {
    final map = payload is Map ? payload : const <String, Object?>{};
    List<Object?>? list;
    for (final key in [...itemKeys, 'items', 'rank_items', 'data', 'list']) {
      final value = map[key];
      if (value is List) {
        list = value;
        break;
      }
    }
    final items = <HamLooseRecord>[
      for (final node in list ?? const <Object?>[]) HamLooseRecord.from(node),
    ];
    return HamLooseSection(
      items: items,
      total: _int(map['total']) ?? items.length,
    );
  }
}

String? _text(Map<dynamic, dynamic> node, List<String> keys) {
  for (final key in keys) {
    final value = node[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is double) return value.round();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
