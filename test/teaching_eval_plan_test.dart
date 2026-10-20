import 'package:campus_atlas/features/teaching_eval/plan.dart';
import 'package:campus_atlas/features/whu_auth/whu_endpoints.dart';
import 'package:campus_atlas/features/whu_auth/whu_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the session-reuse plan.
///
/// What is being pinned down here is mostly *refusal* behaviour: the plan is
/// only worth having if it declines to run when the precondition is not met,
/// because a plan that proceeds on a dead session produces a second sign-in —
/// exactly the thing this technique exists to avoid.
void main() {
  final t0 = DateTime.utc(2026, 10, 14, 9);

  WhuSession session({
    DateTime? at,
    Map<String, String>? cookies,
  }) {
    final all = cookies ??
        const {
          CasOrigin.tgcCookie: 'TGC-abc',
          CasOrigin.sessionCookie: 'SVC',
        };
    return WhuSession(
      cookies: all,
      scoped: [
        for (final e in all.entries)
          if (e.key == CasOrigin.tgcCookie)
            (
              name: e.key,
              value: e.value,
              domain: 'cas.whu.edu.cn',
              path: '/authserver',
              hostOnly: true,
            )
          else
            (
              name: e.key,
              value: e.value,
              domain: 'ugsqs.whu.edu.cn',
              path: '/',
              hostOnly: true,
            ),
      ],
      acquiredAt: at ?? t0,
      properties: const {WhuProperty.jwgl},
    );
  }

  const ttl = Duration(hours: 2);

  group('refusals', () {
    test('no session at all', () {
      final p = TeachingEvalPlan.forSession(null, ttl: ttl, now: t0);
      expect(p.canProceed, isFalse);
      expect(p.refusal, PlanRefusal.noSession);
      expect(p.hops, isEmpty);
    });

    test('a service-local session with no grant is refused', () {
      // This is the load-bearing refusal: a jar without a TGC can talk to the
      // host it came from, but cannot be reused for another property, so
      // proceeding would burn a login attempt for nothing.
      final p = TeachingEvalPlan.forSession(
        session(cookies: const {CasOrigin.sessionCookie: 'service-only'}),
        ttl: ttl,
        now: t0,
      );
      expect(p.refusal, PlanRefusal.noGrant);
      expect(p.canProceed, isFalse);
    });

    test('an expired budget is refused', () {
      final p = TeachingEvalPlan.forSession(
        session(at: t0),
        ttl: ttl,
        now: t0.add(const Duration(hours: 3)),
      );
      expect(p.refusal, PlanRefusal.stale);
      expect(p.canProceed, isFalse);
    });

    test('exactly at the budget boundary it is already refused', () {
      final p = TeachingEvalPlan.forSession(
        session(at: t0),
        ttl: ttl,
        now: t0.add(ttl),
      );
      expect(p.refusal, PlanRefusal.stale);
    });

    test('one second inside the budget it proceeds', () {
      final p = TeachingEvalPlan.forSession(
        session(at: t0),
        ttl: ttl,
        now: t0.add(ttl).subtract(const Duration(seconds: 1)),
      );
      expect(p.canProceed, isTrue);
    });
  });

  group('a workable plan', () {
    late TeachingEvalPlan p;

    setUp(() {
      p = TeachingEvalPlan.forSession(session(at: t0),
          ttl: ttl, now: t0.add(const Duration(minutes: 30)));
    });

    test('refusal is null', () {
      expect(p.refusal, isNull);
      expect(p.canProceed, isTrue);
      expect(p.issuedAt, t0.add(const Duration(minutes: 30)));
    });

    test('reports the remaining budget', () {
      expect(p.remaining, const Duration(minutes: 90));
    });

    test('starts at the teaching-evaluation entry point', () {
      // The first hop is the whole trick: arriving on the service while the
      // CAS session is still live, rather than opening a second login.
      expect(p.hops.first.url, TeachingEvalOrigin.casService);
      expect(p.hops.first.url, 'https://ugsqs.whu.edu.cn/caslogin/');
      expect(p.hops.first.evidence, isFalse,
          reason: 'this hop is from the prior session\'s log; this project '
              'never observed it — flagging it keeps a mismatch legible');
    });

    test('then goes through CAS with the service properly encoded', () {
      final cas = p.hops[1];
      expect(cas.url.startsWith(CasOrigin.login), isTrue);
      expect(cas.evidence, isTrue, reason: 'CAS login itself is verified');
      expect(cas.url,
          contains(Uri.encodeComponent(TeachingEvalOrigin.casService)));

      final service = cas.url.substring(CasOrigin.login.length);
      expect(service, isNot(contains('://')),
          reason: 'an unencoded service would make CAS parse it as garbage');
      expect(Uri.decodeComponent(service), TeachingEvalOrigin.casService);
    });

    test('the ticket hop is marked as a placeholder, not a known URL', () {
      final ticket = p.hops[2];
      expect(ticket.url, contains('ticket={issued}'));
      expect(ticket.evidence, isFalse);
      expect(ticket.url.contains('{issued}'), isTrue,
          reason: 'a server-generated ticket is unpredictable before the run');
    });

    test('exactly three hops, in that order', () {
      expect(p.hops, hasLength(3));
      final urls = p.hops.map((h) => h.url).toList();
      expect(urls[0], TeachingEvalOrigin.casService);
      expect(urls[1], startsWith(CasOrigin.login));
      expect(urls[2], contains('ticket'));
    });

    test('every hop explains itself', () {
      for (final h in p.hops) {
        expect(h.why, isNotEmpty);
      }
    });
  });

  group('budget handling', () {
    test('a tighter ttl is honoured', () {
      final p = TeachingEvalPlan.forSession(
        session(at: t0),
        ttl: const Duration(minutes: 5),
        now: t0.add(const Duration(minutes: 4)),
      );
      expect(p.canProceed, isTrue);
      expect(p.remaining, const Duration(minutes: 1));
    });

    test('a tighter ttl that has run out is refused', () {
      final p = TeachingEvalPlan.forSession(
        session(at: t0),
        ttl: const Duration(minutes: 5),
        now: t0.add(const Duration(minutes: 6)),
      );
      expect(p.refusal, PlanRefusal.stale);
    });

    test('a generous ttl still respects an old session', () {
      final p = TeachingEvalPlan.forSession(
        session(at: t0),
        ttl: const Duration(hours: 12),
        now: t0.add(const Duration(hours: 13)),
      );
      expect(p.refusal, PlanRefusal.stale);
    });

    test('the default budget works without passing one', () {
      final p = TeachingEvalPlan.forSession(session(at: DateTime.now()),
          now: DateTime.now());
      expect(p.canProceed, isTrue);
    });
  });

  group('plan safety', () {
    test('the plan never contains a credential', () {
      // Hops are navigations, not requests; a session identifier must never be
      // embedded in a URL the UI displays or a log records.
      final p = TeachingEvalPlan.forSession(
        session(cookies: {
          CasOrigin.tgcCookie: 'TGC-SECRET-BLOB',
          CasOrigin.sessionCookie: 'JSESSION-SECRET',
        }),
        ttl: ttl,
        now: t0,
      );
      expect(p.canProceed, isTrue);
      final joined = p.hops.map((h) => '${h.url}${h.why}').join(' | ');
      expect(joined, isNot(contains('TGC-SECRET-BLOB')));
      expect(joined, isNot(contains('JSESSION-SECRET')));
    });

    test('a denial carries no cookie material either', () {
      final p = TeachingEvalPlan.forSession(
        session(
          cookies: const {CasOrigin.sessionCookie: 'JSESSION-SECRET'},
          at: t0,
        ),
        ttl: ttl,
        now: t0.add(const Duration(hours: 9)),
      );
      expect(p.refusal, isNotNull);
      expect('$p', isNot(contains('JSESSION-SECRET')));
    });
  });
}
