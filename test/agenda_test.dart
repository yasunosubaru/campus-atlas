import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/core/storage/settings.dart';
import 'package:campus_atlas/features/agenda/agenda_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemorySettingsStore store;
  late DateTime fixedNow;

  AgendaRepository repo() => AgendaRepository(
        store,
        now: () => fixedNow,
      );

  setUp(() {
    store = InMemorySettingsStore();
    fixedNow = DateTime(2026, 10, 14, 9, 30);
  });

  group('create', () {
    test('starts empty', () async {
      final r = await repo().list();
      expect(r.isSuccess, isTrue);
      expect(r.requireValue, isEmpty);
    });

    test('adds an item with a stable id and creation time', () async {
      final r = await repo().create('Buy coffee');
      expect(r.isSuccess, isTrue);
      final items = r.requireValue;
      expect(items, hasLength(1));
      expect(items.first.title, 'Buy coffee');
      expect(items.first.done, isFalse);
      expect(items.first.createdAt, fixedNow);
      expect(items.first.id, isNotEmpty);
    });

    test('trims surrounding whitespace', () async {
      final r = await repo().create('  padded  ');
      expect(r.requireValue.first.title, 'padded');
    });

    test('rejects a blank title', () async {
      final r = await repo().create('   ');
      expect(r.isSuccess, isFalse);
      expect(r.errorOrNull?.kind, FailureKind.validation);
    });

    test('assigns increasing sortOrder', () async {
      final agenda = repo();
      await agenda.create('one');
      await agenda.create('two');
      final r = await agenda.create('three');
      final orders = r.requireValue.map((e) => e.sortOrder).toList();
      expect(orders, [0, 1, 2]);
    });
  });

  group('toggle / update / remove', () {
    test('toggle flips the completed flag', () async {
      final agenda = repo();
      final created = await agenda.create('task');
      final id = created.requireValue.single.id;

      final toggled = await agenda.toggle(id);
      expect(toggled.requireValue.single.done, isTrue);

      final back = await agenda.toggle(id);
      expect(back.requireValue.single.done, isFalse);
    });

    test('toggle of an unknown id is a no-op, not an error', () async {
      final agenda = repo();
      await agenda.create('task');
      final r = await agenda.toggle('does-not-exist');
      expect(r.isSuccess, isTrue);
      expect(r.requireValue.single.done, isFalse);
    });

    test('update replaces the matching item only', () async {
      final agenda = repo();
      await agenda.create('first');
      final second = (await agenda.create('second')).requireValue.last;

      final r = await agenda.update(second.copyWith(title: 'renamed'));
      final titles = r.requireValue.map((e) => e.title).toList();
      expect(titles, ['first', 'renamed']);
    });

    test('remove drops the matching item', () async {
      final agenda = repo();
      final a = (await agenda.create('keep')).requireValue.single;
      // Mutators return the whole updated list, so the second item is `last`.
      final b = (await agenda.create('drop')).requireValue.last;

      final r = await agenda.remove(b.id);
      expect(r.requireValue.map((e) => e.id), [a.id]);
    });

    test('removing everything returns to empty', () async {
      final agenda = repo();
      final a = (await agenda.create('x')).requireValue.single;
      final r = await agenda.remove(a.id);
      expect(r.requireValue, isEmpty);
    });
  });

  group('persistence', () {
    test('items survive a new repository over the same store', () async {
      final agenda = repo();
      await agenda.create('persist me');
      await agenda.create('and me');

      // A fresh repository instance models an app restart.
      final after = await repo().list();
      expect(after.requireValue.map((e) => e.title), ['persist me', 'and me']);
    });

    test('a completed flag survives the round trip', () async {
      final agenda = repo();
      final id = (await agenda.create('done later')).requireValue.single.id;
      await agenda.toggle(id);

      final after = await repo().list();
      expect(after.requireValue.single.done, isTrue);
    });

    test('a due date survives the round trip', () async {
      final due = DateTime(2026, 10, 20, 18);
      await repo().create('deadline', dueDate: due);

      final after = await repo().list();
      expect(after.requireValue.single.dueDate, due);
    });

    test('corrupt stored JSON reports invalidData instead of throwing',
        () async {
      await store.setString('agenda.items', '{not a list');
      final r = await repo().list();
      expect(r.isSuccess, isFalse);
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('a payload that is not a list is rejected', () async {
      await store.setString('agenda.items', '{"a":1}');
      final r = await repo().list();
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('unreadable rows are skipped rather than discarding the list',
        () async {
      await store.setString(
        'agenda.items',
        '[{"id":"a","title":"good","done":false},{"id":42}]',
      );
      final r = await repo().list();
      expect(r.isSuccess, isTrue);
      expect(r.requireValue.map((e) => e.id), ['a']);
    });
  });

  group('AgendaItem JSON', () {
    test('round-trips without a due date', () {
      const item = AgendaItem(id: 'a', title: 't', sortOrder: 3);
      final parsed = AgendaItem.fromJson(item.toJson());
      expect(parsed.isSuccess, isTrue);
      expect(parsed.requireValue.id, 'a');
      expect(parsed.requireValue.sortOrder, 3);
      expect(parsed.requireValue.dueDate, isNull);
    });

    test('rejects an object missing id/title', () {
      final parsed = AgendaItem.fromJson(const {'title': 'x'});
      expect(parsed.errorOrNull?.kind, FailureKind.invalidData);
    });
  });

  group('recurrence', () {
    AgendaItem item({
      DateTime? due,
      RepeatRule repeat = RepeatRule.none,
      DateTime? until,
    }) =>
        AgendaItem(
          id: 'a',
          title: 't',
          dueDate: due,
          repeat: repeat,
          repeatUntil: until,
        );

    test('a one-off task occurs only on its due date', () {
      final a = item(due: DateTime(2026, 10, 20));
      expect(a.occursOn(DateTime(2026, 10, 20)), isTrue);
      expect(a.occursOn(DateTime(2026, 10, 21)), isFalse);
      expect(a.occursOn(DateTime(2026, 10, 19)), isFalse);
    });

    test('a daily task occurs every day from the start', () {
      final a = item(due: DateTime(2026, 10, 20), repeat: RepeatRule.daily);
      expect(a.occursOn(DateTime(2026, 10, 20)), isTrue);
      expect(a.occursOn(DateTime(2026, 10, 25)), isTrue);
      expect(a.occursOn(DateTime(2026, 10, 19)), isFalse);
    });

    test('a weekly task follows the weekday', () {
      final a = item(due: DateTime(2026, 10, 20), repeat: RepeatRule.weekly);
      expect(a.occursOn(DateTime(2026, 10, 27)), isTrue); // next Tuesday
      expect(a.occursOn(DateTime(2026, 10, 28)), isFalse);
    });

    test('a monthly task follows the day of month', () {
      final a = item(due: DateTime(2026, 1, 15), repeat: RepeatRule.monthly);
      expect(a.occursOn(DateTime(2026, 2, 15)), isTrue);
      expect(a.occursOn(DateTime(2026, 3, 15)), isTrue);
      expect(a.occursOn(DateTime(2026, 3, 16)), isFalse);
    });

    test('the end date is inclusive and stops the repetition', () {
      final a = item(
        due: DateTime(2026, 10, 20),
        repeat: RepeatRule.daily,
        until: DateTime(2026, 10, 22),
      );
      expect(a.occursOn(DateTime(2026, 10, 22)), isTrue);
      expect(a.occursOn(DateTime(2026, 10, 23)), isFalse);
    });

    test('nothing occurs without a first date', () {
      final a = item(repeat: RepeatRule.daily);
      expect(a.occursOn(DateTime(2026, 10, 20)), isFalse);
    });

    test('create stores the rule and its end', () async {
      final created = await repo().create(
        'weekly review',
        dueDate: DateTime(2026, 10, 20),
        repeat: RepeatRule.weekly,
        repeatUntil: DateTime(2026, 12, 1),
      );
      final a = created.requireValue.single;
      expect(a.repeat, RepeatRule.weekly);
      expect(a.repeatUntil, DateTime(2026, 12, 1));
    });

    test('a non-repeating create drops any end date', () async {
      final created = await repo().create(
        'once',
        dueDate: DateTime(2026, 10, 20),
        repeatUntil: DateTime(2026, 12, 1),
      );
      expect(created.requireValue.single.repeatUntil, isNull);
    });

    test('the rule and end date survive a restart', () async {
      await repo().create(
        'weekly',
        dueDate: DateTime(2026, 10, 20),
        repeat: RepeatRule.weekly,
        repeatUntil: DateTime(2026, 12, 1),
      );
      final after = (await repo().list()).requireValue.single;
      expect(after.repeat, RepeatRule.weekly);
      expect(after.repeatUntil, DateTime(2026, 12, 1));
    });

    test('an unknown stored rule falls back to none', () {
      final parsed = AgendaItem.fromJson(const {
        'id': 'a',
        'title': 't',
        'dueDate': '2026-10-20T00:00:00.000',
        'repeat': 'fortnightly',
      });
      expect(parsed.requireValue.repeat, RepeatRule.none);
    });
  });
}
