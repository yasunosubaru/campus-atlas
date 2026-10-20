import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A server-issued Altcha proof-of-work challenge.
///
/// Fetched from `GET /api/v1/verification/altcha`, which is public and returns:
///
/// ```
/// {"algorithm":"SHA-256","challenge":"627735...","salt":"1791976232.749c...",
///  "signature":"9fbf...","maxnumber":5000}
/// ```
///
/// Altcha is a **proof-of-work, not a CAPTCHA**: the widget finds a `number`
/// such that `SHA-256(salt + number) == challenge`. Solving it is the intended
/// client-side mechanism — the same computation the original app performs — and
/// not a circumvention of anything. Nothing here guesses, predicts, or bypasses
/// a human challenge; the human-only step is the password, which this file
/// never touches.
class AltchaChallenge {
  const AltchaChallenge({
    required this.algorithm,
    required this.challenge,
    required this.salt,
    required this.signature,
    required this.maxNumber,
  });

  final String algorithm;
  final String challenge;
  final String salt;
  final String signature;
  final int maxNumber;

  /// Parses a challenge, or returns null when the body is not one.
  ///
  /// A non-Altcha body (an HTML error page, a 401 envelope) must yield null
  /// rather than an exception, because a challenge that cannot be read is a
  /// normal outcome when a gate is disabled or a session is already present.
  static AltchaChallenge? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final challenge = raw['challenge'];
    final salt = raw['salt'];
    final signature = raw['signature'];
    if (challenge is! String ||
        challenge.isEmpty ||
        salt is! String ||
        signature is! String) {
      return null;
    }
    var max = 5000;
    final rawMax = raw['maxnumber'];
    if (rawMax is num) max = rawMax.toInt();
    return AltchaChallenge(
      algorithm:
          raw['algorithm'] is String ? raw['algorithm']! as String : 'SHA-256',
      challenge: challenge,
      salt: salt,
      signature: signature,
      maxNumber: max,
    );
  }

  bool get isSolveable => maxNumber > 0 && salt.isNotEmpty;

  /// Solves the proof of work.
  ///
  /// Returns the winning `number`, or null when none was found within
  /// [maxNumber]. The search is bounded by the server's own budget, so it
  /// cannot run away: worst case is [maxNumber] hashes, which at 5000 is
  /// negligible.
  int? solve() {
    if (!isSolveable) return null;
    for (var n = 1; n <= maxNumber; n++) {
      final digest = sha256.convert(utf8.encode('$salt$n')).toString();
      if (digest == challenge) return n;
    }
    return null;
  }

  /// The value to send, once solved.
  ///
  /// Altcha's widget transmits the payload as
  /// `Authorization: Altcha <base64url(json)>`. Base64url (not base64) because
  /// the payload travels in a header, where `+` and `/` are not safe.
  static String encodeSolution({
    required String algorithm,
    required String challenge,
    required int number,
    required String salt,
    required String signature,
  }) {
    final payload = jsonEncode({
      'algorithm': algorithm,
      'challenge': challenge,
      'number': number,
      'salt': salt,
      'signature': signature,
    });
    return base64Url.encode(utf8.encode(payload));
  }

  /// Convenience: solve and encode in one step.
  ///
  /// Returns null when the challenge could not be solved, so a caller can
  /// surface "verification unavailable" rather than sending a malformed login.
  ({int number, String encoded})? solveAndEncode() {
    final n = solve();
    if (n == null) return null;
    return (
      number: n,
      encoded: encodeSolution(
        algorithm: algorithm,
        challenge: challenge,
        number: n,
        salt: salt,
        signature: signature,
      ),
    );
  }
}

/// Verifies a solution locally, which is what makes the solver testable
/// without a server round-trip.
bool verifySolution({
  required String salt,
  required int number,
  required String expectedChallenge,
}) =>
    sha256.convert(utf8.encode('$salt$number')).toString() == expectedChallenge;
