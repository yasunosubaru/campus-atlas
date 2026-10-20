import '../whu_auth/whu_endpoints.dart';
import '../whu_auth/whu_session.dart';

/// Why a teaching-evaluation session-reuse plan cannot proceed, or null when it
/// can. A refusal is typed rather than a message so the UI can say *which*
/// precondition failed without parsing prose.
enum PlanRefusal {
  /// No session has been obtained this run.
  noSession,

  /// The jar has no ticket-granting cookie, so there is nothing to reuse —
  /// this is a service-local session and it cannot be extended.
  noGrant,

  /// The CAS session is past the freshness budget; the TGC may still work, but
  /// so may it not, and spending a login attempt on it is exactly what this
  /// technique exists to avoid.
  stale,

  /// No service URL established for the target.
  noServiceTarget,
}

/// One expected navigation, with the reason it happens.
///
/// [Hops] are an **expected sequence, not an observed one**: `ugsqs` returns no
/// credential-free assets of any kind, so the redirect chain was established by
/// the earlier session's log rather than by this project's own probes. Each hop
/// carries that caveat so a mismatch during a real run reads as "the model was
/// wrong", not as "the code is broken".
class Hop {
  const Hop({required this.url, required this.why, required this.evidence});

  final String url;
  final String why;
  final bool evidence; // true = verified by this project, false = assumed

  @override
  String toString() => 'Hop($url [$evidence])';
}

/// The plan for reaching 教师评教 without a second sign-in.
class TeachingEvalPlan {
  const TeachingEvalPlan.ok({
    required this.hops,
    required this.issuedAt,
    required this.remaining,
  }) : refusal = null;

  const TeachingEvalPlan.denied({required this.refusal})
      : hops = const [],
        issuedAt = null,
        remaining = Duration.zero;

  /// Non-null when the plan is refused.
  final PlanRefusal? refusal;
  final List<Hop> hops;
  final DateTime? issuedAt;

  /// Time left on the CAS session at the moment the plan was made.
  final Duration remaining;

  bool get canProceed => refusal == null;

  /// Builds the plan for [session], or explains why it cannot run.
  ///
  /// [ttl] is the freshness budget. Deliberately generous: the point of the
  /// whole exercise is to *reuse* an existing session rather than minting
  /// another, and an over-tight window would push callers back into repeated
  /// logins against an origin that rate-limits them.
  static TeachingEvalPlan forSession(
    WhuSession? session, {
    Duration ttl = const Duration(hours: 2),
    DateTime? now,
  }) {
    if (session == null) {
      return const TeachingEvalPlan.denied(refusal: PlanRefusal.noSession);
    }
    if (!session.hasTgc) {
      return const TeachingEvalPlan.denied(refusal: PlanRefusal.noGrant);
    }

    final at = now ?? DateTime.now();
    final elapsed = at.difference(session.acquiredAt);
    // `Duration` has no `.difference`; elapsed is computed from the two
    // timestamps and subtracted from the budget.
    if (elapsed >= ttl) {
      return const TeachingEvalPlan.denied(refusal: PlanRefusal.stale);
    }
    final remaining = ttl - elapsed;

    final service = TeachingEvalOrigin.casService;
    if (service.isEmpty) {
      return const TeachingEvalPlan.denied(
          refusal: PlanRefusal.noServiceTarget);
    }

    return TeachingEvalPlan.ok(
      hops: [
        Hop(
          url: service,
          why: 'entry point: arrive while the CAS session is still live, so '
              'the ticket-granting cookie can be redeemed without a second '
              "sign-in and without spending one of this origin's limited "
              'login attempts',
          evidence: false,
        ),
        Hop(
          url: '${CasOrigin.login}${Uri.encodeComponent(service)}',
          why: 'CAS checks the TGC and issues a service ticket — the standard '
              'single sign-on step',
          evidence: true,
        ),
        Hop(
          url: '$service?ticket={issued}',
          why: 'CAS 302s back to the service with the ticket; `{issued}` is '
              'server-generated and unpredictable until the flow runs',
          evidence: false,
        ),
      ],
      issuedAt: at,
      remaining: remaining,
    );
  }
}
