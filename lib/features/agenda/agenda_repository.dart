import 'dart:convert';

import '../../core/result.dart';
import '../../core/storage/settings.dart';

/// How an agenda item repeats.
///
/// Stored by [id] rather than by enum index so reordering this enum cannot
/// silently turn a weekly task into a monthly one.
enum RepeatRule {
  none('none'),
  daily('daily'),
  weekly('weekly'),
  monthly('monthly');

  const RepeatRule(this.id);

  final String id;

  static RepeatRule fromId(String? id) {
    for (final rule in values) {
      if (rule.id == id) return rule;
    }
    return RepeatRule.none;
  }
}

/// A task on the local agenda list.
class AgendaItem {
  const AgendaItem({
    required this.id,
    required this.title,
    this.done = false,
    this.dueDate,
    this.createdAt,
    this.sortOrder = 0,
    this.repeat = RepeatRule.none,
    this.repeatUntil,
  });

  final String id;
  final String title;
  final bool done;
  final DateTime? dueDate;
  final DateTime? createdAt;
  final int sortOrder;

  /// Repetition pattern. Only meaningful together with [dueDate]: without a
  /// first occurrence there is nothing to repeat from.
  final RepeatRule repeat;

  /// Last day the repetition may occur (inclusive), or null for "no end".
  final DateTime? repeatUntil;

  /// Whether this item happens on [day].
  ///
  /// The single rule every view shares — the agenda list, the month grid and
  /// the home screen all ask this question rather than reimplementing it.
  bool occursOn(DateTime day) {
    final due = dueDate;
    if (due == null) return false;

    final start = DateTime(due.year, due.month, due.day);
    final target = DateTime(day.year, day.month, day.day);
    if (target.isBefore(start)) return false;

    final until = repeatUntil;
    if (until != null) {
      final end = DateTime(until.year, until.month, until.day);
      if (target.isAfter(end)) return false;
    }

    return switch (repeat) {
      RepeatRule.none => target.isAtSameMomentAs(start),
      RepeatRule.daily => true,
      RepeatRule.weekly => target.weekday == start.weekday,
      RepeatRule.monthly => target.day == start.day,
    };
  }

  AgendaItem copyWith({
    String? title,
    bool? done,
    DateTime? dueDate,
    int? sortOrder,
    bool clearDue = false,
    RepeatRule? repeat,
    DateTime? repeatUntil,
    bool clearRepeatUntil = false,
  }) =>
      AgendaItem(
        id: id,
        title: title ?? this.title,
        done: done ?? this.done,
        dueDate: clearDue ? null : (dueDate ?? this.dueDate),
        createdAt: createdAt,
        sortOrder: sortOrder ?? this.sortOrder,
        repeat: repeat ?? this.repeat,
        repeatUntil:
            clearRepeatUntil ? null : (repeatUntil ?? this.repeatUntil),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'done': done,
        if (dueDate != null) 'dueDate': dueDate!.toIso8601String(),
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
        'sortOrder': sortOrder,
        'repeat': repeat.id,
        if (repeatUntil != null) 'repeatUntil': repeatUntil!.toIso8601String(),
      };

  static Result<AgendaItem> fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final title = json['title'];
    if (id is! String || title is! String) {
      return Failure<AgendaItem>.reason(
        FailureKind.invalidData,
        message: 'Agenda item missing id/title',
      );
    }
    return Success(
      AgendaItem(
        id: id,
        title: title,
        done: json['done'] == true,
        dueDate: json['dueDate'] is String
            ? DateTime.tryParse(json['dueDate']! as String)
            : null,
        createdAt: json['createdAt'] is String
            ? DateTime.tryParse(json['createdAt']! as String)
            : null,
        sortOrder: json['sortOrder'] is int ? json['sortOrder']! as int : 0,
        repeat: RepeatRule.fromId(
          json['repeat'] is String ? json['repeat']! as String : null,
        ),
        repeatUntil: json['repeatUntil'] is String
            ? DateTime.tryParse(json['repeatUntil']! as String)
            : null,
      ),
    );
  }
}

/// Local-first agenda storage with the same key/value backing as the timetable.
///
/// Mirrors the observed `agenda.*` operation set (list / create / update /
/// delete / toggle / reorder) while remaining entirely on-device: none of this
/// needs a server, and keeping it local means the feature works offline.
class AgendaRepository {
  AgendaRepository(this._store, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final SettingsStore _store;
  final DateTime Function() _now;
  static const String _key = 'agenda.items';

  Future<Result<List<AgendaItem>>> list() async {
    final raw = await _store.getString(_key);
    if (raw.trim().isEmpty) return const Success([]);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return Failure<List<AgendaItem>>.reason(
          FailureKind.invalidData,
          message: 'Agenda payload was not a list',
        );
      }
      final out = <AgendaItem>[];
      for (final item in decoded) {
        if (item is! Map<String, Object?>) continue;
        final parsed = AgendaItem.fromJson(item);
        if (parsed case Success(:final data)) out.add(data);
      }
      out.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      return Success(out);
    } on FormatException catch (e) {
      return Failure<List<AgendaItem>>.reason(
        FailureKind.invalidData,
        message: 'Malformed JSON',
        cause: e,
      );
    }
  }

  Future<Result<List<AgendaItem>>> create(
    String title, {
    DateTime? dueDate,
    RepeatRule repeat = RepeatRule.none,
    DateTime? repeatUntil,
  }) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return Failure<List<AgendaItem>>.reason(
        FailureKind.validation,
        message: 'Title must not be empty',
      );
    }
    final current = await list();
    if (current is Failure) return current;

    final next = [
      ...current.dataOrNull!,
      AgendaItem(
        id: _newId(),
        title: trimmed,
        dueDate: dueDate,
        createdAt: _now(),
        sortOrder: current.dataOrNull!.length,
        repeat: repeat,
        repeatUntil: repeat == RepeatRule.none ? null : repeatUntil,
      ),
    ];
    final saved = await _persist(next);
    if (saved is Failure) return Failure<List<AgendaItem>>(saved.errorOrNull!);
    return Success(next);
  }

  Future<Result<List<AgendaItem>>> update(AgendaItem item) async {
    final current = await list();
    if (current is Failure) return current;
    final next =
        current.dataOrNull!.map((e) => e.id == item.id ? item : e).toList();
    final saved = await _persist(next);
    if (saved is Failure) return Failure<List<AgendaItem>>(saved.errorOrNull!);
    return Success(next);
  }

  Future<Result<List<AgendaItem>>> toggle(String id) async {
    final current = await list();
    if (current is Failure) return current;
    final next = current.dataOrNull!
        .map((e) => e.id == id ? e.copyWith(done: !e.done) : e)
        .toList();
    final saved = await _persist(next);
    if (saved is Failure) return Failure<List<AgendaItem>>(saved.errorOrNull!);
    return Success(next);
  }

  Future<Result<List<AgendaItem>>> remove(String id) async {
    final current = await list();
    if (current is Failure) return current;
    final next = current.dataOrNull!.where((e) => e.id != id).toList();
    final saved = await _persist(next);
    if (saved is Failure) return Failure<List<AgendaItem>>(saved.errorOrNull!);
    return Success(next);
  }

  Future<Result<void>> _persist(List<AgendaItem> items) async {
    // `.toList()` matters: jsonEncode cannot serialise the lazy
    // MappedListIterable that .map() returns, and it fails only at runtime.
    await _store.setString(
      _key,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
    return const Success(null);
  }

  String _newId() {
    _counter += 1;
    return 'a${_now().microsecondsSinceEpoch.toRadixString(36)}'
        '_${_counter.toRadixString(36)}';
  }

  static var _counter = 0;
}
