import 'package:campus_atlas/features/timetable/import/jwgl_timetable_page_parser.dart';
import 'package:campus_atlas/features/whu_auth/whu_endpoints.dart' show WhuTerm;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseJwglTimetableList', () {
    test('reads the rendered N2151 list rows', () {
      final payload = {
        'ok': true,
        'rows': [
          {
            'day': '星期日',
            'periods': '3-4',
            'text': '【调】数字信号处理周数：第3周上课地点：3区1-615'
                '教师：龚韵教学班：(2026-2027-1)-3001300011004-01'
                '学分：2.5重修标记：',
          },
          {
            'day': '星期一',
            'periods': '3-4',
            'text': '大学物理A（下）周数：1-4周,6-16周'
                '上课地点：1区5-403教师：黄慧明教学班：'
                '(2026-2027-1)-1100860011002-01学分：4重修标记：',
          },
          {
            'day': '星期一',
            'periods': '8-9',
            'text': '数学物理方法周数：1-4周,6-14周'
                '上课地点：1区5-501教师：余雄东教学班：'
                '(2026-2027-1)-3001300011003-08学分：3.5重修标记：',
          },
        ],
      };

      final result = parseJwglTimetableList(payload);
      expect(result.errorOrNull, isNull);
      final import = result.requireValue;
      expect(import.courses, hasLength(3));

      final dsp = import.courses.firstWhere((c) => c.name == '数字信号处理');
      expect(dsp.weekday, 7);
      expect(dsp.startPeriod, 3);
      expect(dsp.periodCount, 2);
      expect(dsp.weeks, {3});
      expect(dsp.teacher, '龚韵');
      expect(dsp.location, '3区1-615');

      final physics = import.courses.firstWhere((c) => c.name == '大学物理A（下）');
      expect(physics.weekday, 1);
      expect(physics.startPeriod, 3);
      expect(physics.weeks, containsAll(<int>[1, 2, 3, 4, 6, 16]));
      expect(physics.weeks, isNot(contains(5)));
      expect(physics.teacher, '黄慧明');
      expect(physics.location, '1区5-403');
    });

    test('accepts a JSON string and keeps an unplaced room empty', () {
      const payload = '{"ok":true,"rows":[{"day":"星期二","periods":"6-8",'
          '"text":"现代电子实验基础周数：第9周上课地点：未排地点'
          '教师：罗嘉辉教学班：x学分：1重修标记："}]}';

      final result = parseJwglTimetableList(payload);
      expect(result.errorOrNull, isNull);
      final course = result.requireValue.courses.single;
      expect(course.name, '现代电子实验基础');
      expect(course.weekday, 2);
      expect(course.startPeriod, 6);
      expect(course.periodCount, 3);
      expect(course.weeks, {9});
      expect(course.location, isEmpty);
    });

    test('counts a row with no week range as skipped', () {
      final result = parseJwglTimetableList({
        'ok': true,
        'rows': [
          {'day': '星期三', 'periods': '1-2', 'text': '只有名字没有周次'},
        ],
      });
      expect(result.errorOrNull, isNull);
      expect(result.requireValue.courses, isEmpty);
      expect(result.requireValue.skipped, 1);
      expect(result.requireValue.problems, isNotEmpty);
    });

    test('the list header row is never a course', () {
      // 星期 | 节次 | 课表信息 — the header of the rendered list.
      final result = parseJwglTimetableList({
        'ok': true,
        'rows': [
          {'day': '星期', 'periods': '节次', 'text': '课表信息'},
          {
            'day': '星期日',
            'periods': '3-4',
            'text': '数字信号处理周数：第3周上课地点：3区1-615教师：龚韵',
          },
        ],
      });
      expect(result.errorOrNull, isNull);
      final import = result.requireValue;
      expect(import.courses, hasLength(1));
      expect(import.courses.single.name, '数字信号处理');
      expect(import.skipped, 1);
    });

    test('a page script failure is a typed failure', () {
      final result = parseJwglTimetableList({
        'ok': false,
        'reason': '请先在页面点“查询”并完成滑块。',
      });
      expect(result.dataOrNull, isNull);
      expect(result.errorOrNull?.message, contains('滑块'));
    });

    test('the year and term come from the page, not from the sheet', () {
      // The week anchor that follows an import is derived from the term, so
      // the term the courses were actually read for has to travel with them.
      final result = parseJwglTimetableList({
        'ok': true,
        'year': '2026',
        'term': '3',
        'rows': [
          {
            'day': '星期日',
            'periods': '3-4',
            'text': '数字信号处理周数：第3周上课地点：3区1-615教师：龚韵',
          },
        ],
      });
      expect(result.errorOrNull, isNull);
      final page = result.requireValue;
      expect(page.year, '2026');
      expect(page.term, WhuTerm.first);
      expect(page.courses, hasLength(1));
    });

    test('a page without a year or term does not guess one', () {
      final result = parseJwglTimetableList({
        'ok': true,
        'rows': [
          {
            'day': '星期日',
            'periods': '3-4',
            'text': '数字信号处理周数：第3周上课地点：3区1-615教师：龚韵',
          },
        ],
      });
      expect(result.errorOrNull, isNull);
      final page = result.requireValue;
      expect(page.year, isNull);
      expect(page.term, isNull);
    });
  });
}
