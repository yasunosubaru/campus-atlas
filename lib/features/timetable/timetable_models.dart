import '../../core/result.dart';

/// A single class occurrence in a weekly timetable.
class Course {
  const Course({
    required this.id,
    required this.name,
    required this.weekday,
    required this.startPeriod,
    required this.periodCount,
    required this.weeks,
    this.teacher = '',
    this.location = '',
    this.startTime = '',
    this.endTime = '',
  });

  final String id;
  final String name;

  /// 1 = Monday … 7 = Sunday.
  final int weekday;

  /// 1-based index of the first period.
  final int startPeriod;

  /// How many consecutive periods the class runs.
  final int periodCount;

  /// Explicit set of teaching weeks (1-based). Stored expanded so that
  /// "every week except 8" and "odd weeks only" need no special syntax later.
  final Set<int> weeks;

  final String teacher;
  final String location;

  /// Clock time of the first period, `HH:mm`, when the source provides it.
  ///
  /// Optional because it is not always known: the academic system's timetable
  /// carries start/end times (`qsjsj`/`jssj`) and an imported course therefore
  /// has them, while a hand-entered one may not. The reminder feature uses them
  /// when present and stays silent otherwise — inventing a period-to-clock table
  /// would put a wrong time in front of someone hurrying to class.
  final String startTime;

  /// Clock time the class ends, `HH:mm`, when known.
  final String endTime;

  int get endPeriod => startPeriod + periodCount - 1;

  bool occursInWeek(int week) => weeks.contains(week);

  Course copyWith({
    String? name,
    int? weekday,
    int? startPeriod,
    int? periodCount,
    Set<int>? weeks,
    String? teacher,
    String? location,
    String? startTime,
    String? endTime,
  }) =>
      Course(
        id: id,
        name: name ?? this.name,
        weekday: weekday ?? this.weekday,
        startPeriod: startPeriod ?? this.startPeriod,
        periodCount: periodCount ?? this.periodCount,
        weeks: weeks ?? this.weeks,
        teacher: teacher ?? this.teacher,
        location: location ?? this.location,
        startTime: startTime ?? this.startTime,
        endTime: endTime ?? this.endTime,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'weekday': weekday,
        'startPeriod': startPeriod,
        'periodCount': periodCount,
        'weeks': weeks.toList()..sort(),
        'teacher': teacher,
        'location': location,
        'startTime': startTime,
        'endTime': endTime,
      };

  static Result<Course> fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final weekday = json['weekday'];
    final start = json['startPeriod'];
    final count = json['periodCount'];
    final weeks = json['weeks'];

    if (id is! String ||
        name is! String ||
        weekday is! int ||
        start is! int ||
        count is! int ||
        weeks is! List) {
      return Failure<Course>.reason(
        FailureKind.invalidData,
        message: 'Course JSON has wrong field types',
      );
    }
    return Success(
      Course(
        id: id,
        name: name,
        weekday: weekday,
        startPeriod: start,
        periodCount: count,
        weeks: weeks.whereType<int>().toSet(),
        teacher: json['teacher'] is String ? json['teacher']! as String : '',
        location: json['location'] is String ? json['location']! as String : '',
        startTime:
            json['startTime'] is String ? json['startTime']! as String : '',
        endTime: json['endTime'] is String ? json['endTime']! as String : '',
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Course &&
      other.id == id &&
      other.name == name &&
      other.weekday == weekday &&
      other.startPeriod == startPeriod &&
      other.periodCount == periodCount &&
      other.weeks.length == weeks.length &&
      other.weeks.containsAll(weeks) &&
      other.teacher == teacher &&
      other.location == location &&
      other.startTime == startTime &&
      other.endTime == endTime;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        weekday,
        startPeriod,
        periodCount,
        Object.hashAllUnordered(weeks),
        teacher,
        location,
        startTime,
        endTime,
      );
}

/// One named timetable. A person can keep several — the main term, a minor, a
/// friend's timetable to compare against — and the grid shows the active one.
class TimetableProfile {
  const TimetableProfile({required this.id, this.name = ''});

  final String id;

  /// User-visible name. Empty means "not named": the UI substitutes a localized
  /// default rather than this layer baking a language into stored data.
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  static Result<TimetableProfile> fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      return Failure<TimetableProfile>.reason(
        FailureKind.invalidData,
        message: 'Timetable profile is missing an id',
      );
    }
    return Success(
      TimetableProfile(
        id: id,
        name: json['name'] is String ? json['name']! as String : '',
      ),
    );
  }
}

/// Parses a human week specification into an explicit set of week numbers.
///
/// Accepted forms, comma separated:
///  * `1-16`   a closed range
///  * `3,5,7`  individual weeks
///  * `1-8,10` mixed
///  * `odd` / `even`  all odd or all weeks up to [throughWeek]
///
/// This is deliberately a pure function: week parsing is where a timetable
/// feature most often goes wrong, so it needs to be testable in isolation.
Result<Set<int>> parseWeeks(
  String input, {
  int throughWeek = 30,
}) {
  final raw = input.trim().toLowerCase();
  if (raw.isEmpty) {
    return Failure<Set<int>>.reason(
      FailureKind.validation,
      message: 'Empty week specification',
    );
  }

  if (raw == 'odd') {
    return Success({for (var w = 1; w <= throughWeek; w += 2) w});
  }
  if (raw == 'even') {
    return Success({for (var w = 2; w <= throughWeek; w += 2) w});
  }

  final weeks = <int>{};
  for (final token in raw.split(RegExp(r'[,\s]+'))) {
    if (token.isEmpty) continue;

    final range = token.split('-');
    if (range.length == 1) {
      final n = int.tryParse(range[0]);
      if (n == null || n < 1) return _badSpec(input);
      weeks.add(n);
      continue;
    }
    if (range.length != 2) return _badSpec(input);

    final from = int.tryParse(range[0]);
    final to = int.tryParse(range[1]);
    if (from == null || to == null || from < 1 || to < from) {
      return _badSpec(input);
    }
    weeks.addAll(List.generate(to - from + 1, (i) => from + i));
  }

  if (weeks.isEmpty) return _badSpec(input);
  return Success(weeks);
}

Failure<Set<int>> _badSpec(String input) => Failure<Set<int>>.reason(
      FailureKind.validation,
      message: 'Unparsable week specification: "$input"',
    );

/// Renders a week set back to the compact `1-16` style form.
String formatWeeks(Set<int> weeks) {
  if (weeks.isEmpty) return '';
  final sorted = weeks.toList()..sort();
  final parts = <String>[];
  var start = sorted.first;
  var prev = sorted.first;

  void flush() {
    parts.add(start == prev ? '$start' : '$start-$prev');
  }

  for (var i = 1; i < sorted.length; i++) {
    final n = sorted[i];
    if (n == prev + 1) {
      prev = n;
      continue;
    }
    flush();
    start = n;
    prev = n;
  }
  flush();
  return parts.join(',');
}

/// One cell of the weekly grid: a period range on a weekday.
class TimeSlot {
  const TimeSlot(
      {required this.courses,
      required this.startPeriod,
      required this.periodCount});
  final List<Course> courses;
  final int startPeriod;
  final int periodCount;
}
