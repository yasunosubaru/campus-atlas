import 'dart:convert';

import '../../core/result.dart';
import '../../core/storage/settings.dart';

/// A course-evaluation draft written ahead of time.
///
/// The school's evaluation page is timed, and the app does not fill it in: its
/// form has never been captured. Writing the text here — where there is no
/// clock — and pasting it into the page is the honest way to help with that
/// step without pretending to know the form.
class ReviewDraft {
  const ReviewDraft({
    required this.id,
    required this.courseName,
    this.teacher = '',
    this.rating = 0,
    this.text = '',
    this.term = '',
    this.updatedAt,
  });

  final String id;
  final String courseName;
  final String teacher;

  /// 1–5, or 0 when unrated.
  final int rating;

  final String text;
  final String term;
  final DateTime? updatedAt;

  ReviewDraft copyWith({
    String? courseName,
    String? teacher,
    int? rating,
    String? text,
    String? term,
    DateTime? updatedAt,
  }) =>
      ReviewDraft(
        id: id,
        courseName: courseName ?? this.courseName,
        teacher: teacher ?? this.teacher,
        rating: rating ?? this.rating,
        text: text ?? this.text,
        term: term ?? this.term,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// What the clipboard gets: a heading, the stars, then the text — so a paste
  /// into a single textarea still reads like a review.
  String get asText => [
        courseName,
        if (teacher.isNotEmpty) teacher,
        if (rating > 0) '★' * rating,
        if (text.isNotEmpty) text,
      ].join('\n');

  Map<String, Object?> toJson() => {
        'id': id,
        'courseName': courseName,
        'teacher': teacher,
        'rating': rating,
        'text': text,
        'term': term,
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      };

  static Result<ReviewDraft> fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final courseName = json['courseName'];
    if (id is! String || courseName is! String) {
      return Failure<ReviewDraft>.reason(
        FailureKind.invalidData,
        message: 'Review draft missing id/courseName',
      );
    }
    final rating = json['rating'];
    return Success(
      ReviewDraft(
        id: id,
        courseName: courseName,
        teacher: json['teacher'] is String ? json['teacher']! as String : '',
        rating: rating is int ? rating.clamp(0, 5) : 0,
        text: json['text'] is String ? json['text']! as String : '',
        term: json['term'] is String ? json['term']! as String : '',
        updatedAt: json['updatedAt'] is String
            ? DateTime.tryParse(json['updatedAt']! as String)
            : null,
      ),
    );
  }
}

/// Local storage for review drafts, one JSON document like the other lists.
class ReviewDraftRepository {
  ReviewDraftRepository(this._store, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final SettingsStore _store;
  final DateTime Function() _now;
  static const String _key = 'reviews.drafts';

  Future<Result<List<ReviewDraft>>> list() async {
    final raw = await _store.getString(_key);
    if (raw.trim().isEmpty) return const Success(<ReviewDraft>[]);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return Failure<List<ReviewDraft>>.reason(
          FailureKind.invalidData,
          message: 'Review drafts were not a list',
        );
      }
      final out = <ReviewDraft>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final parsed =
            ReviewDraft.fromJson(Map<String, Object?>.from(item)).dataOrNull;
        if (parsed != null) out.add(parsed);
      }
      out.sort((a, b) {
        final at = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });
      return Success(out);
    } catch (e) {
      return Failure<List<ReviewDraft>>.reason(
        FailureKind.invalidData,
        message: 'Review drafts could not be decoded: $e',
      );
    }
  }

  /// Inserts a new draft or replaces the one with the same id.
  Future<Result<List<ReviewDraft>>> upsert(ReviewDraft draft) async {
    final name = draft.courseName.trim();
    if (name.isEmpty) {
      return Failure<List<ReviewDraft>>.reason(
        FailureKind.validation,
        message: 'A review draft needs a course name',
      );
    }
    final current = await list();
    if (current is Failure<List<ReviewDraft>>) return current;

    final stamped = draft.copyWith(courseName: name, updatedAt: _now());
    final next = [
      for (final existing in current.requireValue)
        if (existing.id != stamped.id) existing,
      stamped,
    ];
    return _persist(next);
  }

  Future<Result<List<ReviewDraft>>> remove(String id) async {
    final current = await list();
    if (current is Failure<List<ReviewDraft>>) return current;
    final next =
        current.requireValue.where((draft) => draft.id != id).toList();
    return _persist(next);
  }

  Future<Result<List<ReviewDraft>>> _persist(List<ReviewDraft> drafts) async {
    final next = [...drafts]..sort((a, b) {
        final at = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });
    await _store.setString(
      _key,
      jsonEncode([for (final draft in next) draft.toJson()]),
    );
    return Success(next);
  }
}
