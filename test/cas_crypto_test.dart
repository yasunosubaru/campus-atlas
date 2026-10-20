import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:campus_atlas/features/whu_auth/cas_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The random source shared with the reference implementation.
///
/// The reference's `randomString` draws from `Math.random()`, so two runs never
/// agree unless the sequence is pinned. Both sides therefore step the same small
/// LCG: exact in Dart's 64-bit `int`, and exact in JavaScript because the
/// generator uses `BigInt` rather than `Math.imul`. If this ever drifts from
/// `bin/gen_cas_password_vectors.js` / `bin/verify_cas_crypto.dart`, every vector
/// fails at once — which is the loud, obvious failure we want, not a subtle one.
class _ReferenceRandom implements Random {
  _ReferenceRandom(int seed) : _state = seed % _modulus;

  static const int _modulus = 2147483648; // 2^31

  int _state;

  @override
  double nextDouble() {
    _state = (_state * 1103515245 + 12345) % _modulus;
    return _state / _modulus;
  }

  @override
  int nextInt(int max) => (nextDouble() * max).floor();

  @override
  bool nextBool() => nextDouble() < 0.5;
}

Map<String, Object?> _loadFixture() {
  final file = File('test/fixtures/cas_password_vectors.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

void main() {
  final fixture = _loadFixture();

  // The vectors are the vendor's output, not ours. Everything below asserts
  // against `encrypt.js` as it is served today; none of it was written by
  // running this implementation and recording what it produced.
  group('CAS password encryption, against the page\'s own encrypt.js', () {
    test('the alphabet matches the reference', () {
      expect(fixture['alphabet'], casAesAlphabet);
      // Pinned so a "helpful" widening of the character set is caught: the
      // alphabet is 48 characters, and neither 49 nor the usual A-Za-z0-9.
      expect(casAesAlphabet.length, 48);
    });

    test('a 16-character salt is the only shape the page emits', () {
      // Not an assumption about the algorithm — an observation from the two live
      // page loads this project has captured, both of which served
      // `dYuZ3fFS2uIolipS` and `rjBFAaHsNkKAhpoi`.
      for (final salt in ['dYuZ3fFS2uIolipS', 'rjBFAaHsNkKAhpoi']) {
        expect(utf8.encode(salt).length, 16);
      }
    });

    final vectors = fixture['vectors']! as List<Object?>;
    test('the fixture carries vectors to check', () {
      expect(vectors, isNotEmpty);
    });

    for (final entry in vectors) {
      final v = entry as Map<String, Object?>;
      final name = v['name']! as String;

      test('$name matches the reference byte for byte', () {
        final actual = casEncryptPassword(
          password: v['password']! as String,
          salt: v['salt']! as String,
          random: _ReferenceRandom(v['seed']! as int),
        );

        expect(actual.wasEncrypted, v['wasEncrypted']);
        expect(actual.value, v['expected']);
      });
    }

    test('the empty-salt vector really is the password, not ciphertext', () {
      // Guards the vector itself: if `expected` were ever regenerated from a
      // build that encrypted unconditionally, this is the vector that would
      // change, and it would change silently.
      final empty = vectors
          .cast<Map<String, Object?>>()
          .firstWhere((v) => v['salt'] == '');
      expect(empty['password'], empty['expected']);
      expect(empty['wasEncrypted'], isFalse);
    });
  });

  group('recorded divergences from the reference', () {
    final divergences =
        (fixture['divergences']! as List<Object?>).cast<Map<String, Object?>>();

    test('there is at least one, and it is documented', () {
      expect(divergences, isNotEmpty);
      for (final d in divergences) {
        // Without `why` a future reader sees a failing case with no reason to
        // keep it failing, and "fixes" it by making the encoder agree with a
        // reference that produces undecryptable requests.
        expect(d['why'], isNotEmpty);
        expect(d['vendorExpected'], isNotEmpty);
      }
    });

    for (final d in divergences) {
      final name = d['name']! as String;

      test('$name raises instead of encrypting under an impossible key', () {
        expect(
          () => casEncryptPassword(
            password: d['password']! as String,
            salt: d['salt']! as String,
            random: _ReferenceRandom(d['seed']! as int),
          ),
          throwsA(isA<ArgumentError>()),
        );
      });
    }

    test('the zero-length-key case says so in its own words', () {
      final blank = divergences.firstWhere((d) => d['name'] == 'blank-salt');
      expect(blank['why'], contains('zero-length AES key'));
    });
  });

  group('salt handling', () {
    test('only the key is trimmed, never the plaintext', () {
      // The 64-character prefix is prepended *after* the trim in the reference,
      // so a password with surrounding spaces keeps them. Getting this backwards
      // is invisible on an ASCII test without spaces — which is why one vector
      // carries spaces on both sides.
      final paddedSalt = casEncryptPassword(
        password: '  padded pass  ',
        salt: '  dYuZ3fFS2uIolipS  ',
        random: _ReferenceRandom(5),
      );
      final bareSalt = casEncryptPassword(
        password: '  padded pass  ',
        salt: 'dYuZ3fFS2uIolipS',
        random: _ReferenceRandom(5),
      );
      expect(paddedSalt.value, bareSalt.value);

      final trimmedPlain = casEncryptPassword(
        password: 'padded pass',
        salt: '  dYuZ3fFS2uIolipS  ',
        random: _ReferenceRandom(5),
      );
      expect(paddedSalt.value, isNot(trimmedPlain.value));
    });

    test('a non-16/24/32 byte key is refused rather than guessed at', () {
      expect(
        () => casEncryptPassword(
          password: 'x',
          salt: 'tooshort',
          random: _ReferenceRandom(1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the 64-character prefix is drawn before the IV', () {
      // Order is not interchangeable: reversing it gives ciphertext of exactly
      // the right length with completely different bytes. This pins it against a
      // random source whose first draw is distinguishable from its second.
      final value = casEncryptPassword(
        password: 'hunter2',
        salt: 'dYuZ3fFS2uIolipS',
        random: _ReferenceRandom(1),
      ).value;
      expect(
          value,
          (fixture['vectors']! as List<Object?>)
              .cast<Map<String, Object?>>()
              .firstWhere((v) => v['name'] == 'ascii-short')['expected']);
    });
  });
}
