import 'package:campus_atlas/core/result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Result', () {
    test('Success exposes its payload through dataOrNull', () {
      const r = Success(42);
      expect(r.isSuccess, isTrue);
      expect(r.dataOrNull, 42);
      expect(r.errorOrNull, isNull);
    });

    test('Failure exposes its reason through errorOrNull', () {
      const r = Failure<int>(AppFailure(FailureKind.network, message: 'x'));
      expect(r.isSuccess, isFalse);
      expect(r.dataOrNull, isNull);
      expect(r.errorOrNull?.kind, FailureKind.network);
      expect(r.errorOrNull?.message, 'x');
    });

    test('requireValue returns the payload for Success', () {
      expect(const Success('ok').requireValue, 'ok');
    });

    test('requireValue throws the AppFailure for Failure', () {
      const r = Failure<String>(
        AppFailure(FailureKind.timeout, message: 'too slow'),
      );
      expect(
        () => r.requireValue,
        throwsA(
          isA<AppFailure>().having((f) => f.kind, 'kind', FailureKind.timeout),
        ),
      );
    });

    test('fold routes to the matching branch', () {
      const ok = Success(1);
      const bad = Failure<int>(AppFailure(FailureKind.server));

      expect(ok.fold((d) => d * 10, (_) => -1), 10);
      expect(bad.fold((d) => d * 10, (_) => -1), -1);
    });

    test('map transforms only the success payload', () {
      const ok = Success(2);
      const bad = Failure<int>(AppFailure(FailureKind.unknown));

      final mappedOk = ok.map((d) => '$d!');
      final mappedBad = bad.map((d) => '$d!');

      expect(mappedOk.dataOrNull, '2!');
      expect(mappedBad.dataOrNull, isNull);
      expect(mappedBad.errorOrNull?.kind, FailureKind.unknown);
    });

    test('reason() forwards every field into the AppFailure', () {
      final cause = Exception('boom');
      final r = Failure<void>.reason(
        FailureKind.protocol,
        message: 'html body',
        statusCode: 200,
        cause: cause,
        endpoint: 'https://example.test/',
      );

      final f = r.errorOrNull!;
      expect(f.kind, FailureKind.protocol);
      expect(f.message, 'html body');
      expect(f.statusCode, 200);
      expect(f.cause, same(cause));
      expect(f.endpoint, 'https://example.test/');
    });

    test('every failure kind has a human-readable label', () {
      for (final kind in FailureKind.values) {
        expect(
          AppFailure(kind).displayLabel,
          isNotEmpty,
          reason: 'kind ${kind.name} has no displayLabel',
        );
      }
    });
  });

  group('FailureKind', () {
    test('covers the transport and content cases we classify', () {
      expect(
        FailureKind.values.toSet(),
        containsAll({
          FailureKind.network,
          FailureKind.timeout,
          FailureKind.unauthorized,
          FailureKind.challengeRequired,
          FailureKind.rateLimited,
          FailureKind.protocol,
          FailureKind.server,
          FailureKind.invalidData,
          FailureKind.validation,
          FailureKind.unsupported,
          FailureKind.unknown,
        }),
      );
    });
  });

  group('isFailure', () {
    test('is the complement of isSuccess', () {
      const ok = Success(1);
      const bad = Failure<int>(AppFailure(FailureKind.network));

      expect(ok.isSuccess, isTrue);
      expect(ok.isFailure, isFalse);
      expect(bad.isSuccess, isFalse);
      expect(bad.isFailure, isTrue);
    });

    test('holds through Result<T> static types', () {
      // The reason this getter exists: `!r.isSuccess` at every failure site is
      // a double negative, and failure branches are where mis-typing hides.
      Result<String> r = const Failure<String>(
        AppFailure(FailureKind.unauthorized),
      );
      expect(r.isFailure, isTrue);

      r = const Success('x');
      expect(r.isFailure, isFalse);
    });
  });
}
