import 'dart:convert';

import 'package:campus_atlas/features/grades_query/altcha.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The salt value from a real challenge the live endpoint answered.
const _salt = '1791976232.749c96dc638229c2';

/// Builds a challenge the way the server does: SHA-256 over `salt + number`.
String _challengeFor(int number) =>
    sha256.convert(utf8.encode('$_salt$number')).toString();

AltchaChallenge _challenge(String challenge, {int maxNumber = 5000}) =>
    AltchaChallenge(
      algorithm: 'SHA-256',
      challenge: challenge,
      salt: _salt,
      signature:
          '9fbf1a78b07ca1bafebcd2ea8ffb19a33de8d43e47cdc6447ab14c0be0b77c7f',
      maxNumber: maxNumber,
    );

void main() {
  group('solve', () {
    test('finds the number the server picked', () {
      for (final number in const [1, 7, 42, 999, 4999]) {
        expect(_challenge(_challengeFor(number)).solve(), number,
            reason: 'number was $number');
      }
    });

    test('the solved number hashes back to the challenge', () {
      // The property that actually matters: solve() output is verifiable, so
      // the value sent to the server is the one it will accept.
      final number = 3712;
      final solved = _challenge(_challengeFor(number)).solve();
      expect(solved, number);
      expect(
        verifySolution(
          salt: _salt,
          number: solved!,
          expectedChallenge: _challengeFor(number),
        ),
        isTrue,
      );
    });

    test('the previous number does not verify', () {
      expect(
        verifySolution(
          salt: _salt,
          number: 3711,
          expectedChallenge: _challengeFor(3712),
        ),
        isFalse,
      );
    });

    test('returns null when the answer is beyond the server budget', () {
      // The bound is the server's, not ours: exceeding it must fail rather
      // than spin past the request budget.
      final challenge = _challengeFor(6000);
      expect(_challenge(challenge, maxNumber: 5000).solve(), isNull);
    });

    test('returns null when the salt is empty', () {
      final c = AltchaChallenge(
        algorithm: 'SHA-256',
        challenge: _challengeFor(3),
        salt: '',
        signature: 'sig',
        maxNumber: 100,
      );
      expect(c.solve(), isNull);
    });

    test('returns null when maxNumber is zero', () {
      final c = AltchaChallenge(
        algorithm: 'SHA-256',
        challenge: 'x',
        salt: _salt,
        signature: '',
        maxNumber: 0,
      );
      expect(c.solve(), isNull);
      expect(c.isSolveable, isFalse);
    });

    test('solving is bounded work, not unbounded', () {
      // A challenge with no solution inside the budget must return quickly
      // rather than searching forever.
      final sw = Stopwatch()..start();
      _challenge('deadbeef', maxNumber: 5000).solve();
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });

  group('tryParse', () {
    test('reads the exact body the live endpoint returns', () {
      final c = AltchaChallenge.tryParse(const {
        'algorithm': 'SHA-256',
        'challenge':
            '627735522cd716127d57cd0bfb2d6375f3f404a740493d8891aba1332fabdcc3',
        'salt': _salt,
        'signature':
            '9fbf1a78b07ca1bafebcd2ea8ffb19a33de8d43e47cdc6447ab14c0be0b77c7f',
        'maxnumber': 5000,
      });
      expect(c, isNotNull);
      expect(c!.algorithm, 'SHA-256');
      expect(c.maxNumber, 5000);
      expect(c.isSolveable, isTrue);
    });

    test('a non-challenge body yields null rather than throwing', () {
      for (final body in const <Object?>[
        null,
        'plain text',
        <String, Object?>{},
        <String, Object?>{'challenge': 'x'}, // missing salt+signature
        <String, Object?>{'salt': 's', 'signature': 'g'}, // missing challenge
      ]) {
        expect(AltchaChallenge.tryParse(body), isNull, reason: '$body');
      }
    });

    test('defaults maxNumber when the server omits it', () {
      final c = AltchaChallenge.tryParse(const {
        'challenge': 'c',
        'salt': 's',
        'signature': 'g',
      });
      expect(c!.maxNumber, 5000);
    });
  });

  group('encodeSolution', () {
    test('produces base64url that decodes back to the payload', () {
      final encoded = AltchaChallenge.encodeSolution(
        algorithm: 'SHA-256',
        challenge: 'ch',
        number: 42,
        salt: _salt,
        signature: 'sig',
      );

      // base64url, not base64: + and / would be unsafe in a header value.
      expect(encoded, isNot(contains('+')), reason: '+ is unsafe in a header');
      expect(encoded, isNot(contains('/')));

      final decoded = jsonDecode(utf8.decode(base64Url.decode(encoded)))
          as Map<String, Object?>;
      expect(decoded['number'], 42);
      expect(decoded['salt'], _salt);
      expect(decoded['challenge'], 'ch');
      expect(decoded['algorithm'], 'SHA-256');
      expect(decoded['signature'], 'sig');
    });

    test('solveAndEncode returns both halves', () {
      final number = 17;
      final solved =
          _challenge(_challengeFor(number), maxNumber: 100).solveAndEncode();
      expect(solved, isNotNull);
      expect(solved!.number, 17);

      final decoded = jsonDecode(utf8.decode(base64Url.decode(solved.encoded)))
          as Map<String, Object?>;
      expect(decoded['number'], 17);
      expect(decoded['salt'], _salt);
    });

    test('solveAndEncode is null when unsolvable', () {
      final c = _challenge(_challengeFor(99999), maxNumber: 10);
      expect(c.solveAndEncode(), isNull);
    });
  });
}
