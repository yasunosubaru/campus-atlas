/// A small explicit result type so failures are never silently swallowed.
///
/// Two types, deliberately:
///  * [Result] / [Success] / [Failure] — the *outcome* of an operation.
///  * [AppFailure] — the *reason* it failed, which travels inside a [Failure].
///
/// Campus backends misbehave in interesting ways (expired CAS session, a
/// captive portal answering instead of JSON, a maintenance window). Throwing
/// a raw exception across repository boundaries loses the *kind* of failure,
/// which is exactly what the UI needs in order to decide between "offer a
/// retry" and "ask the user to sign in again".
sealed class Result<T> {
  const Result();

  R fold<R>(R Function(T data) ok, R Function(AppFailure failure) err) =>
      switch (this) {
        Success<T>(:final data) => ok(data),
        Failure<T>(:final failure) => err(failure),
      };

  T get requireValue => switch (this) {
        Success<T>(:final data) => data,
        Failure<T>(:final failure) => throw failure,
      };

  Result<R> map<R>(R Function(T data) f) => switch (this) {
        Success<T>(:final data) => Success(f(data)),
        Failure<T>(:final failure) => Failure<R>(failure),
      };

  /// The [AppFailure] when this is a failure, otherwise null.
  AppFailure? get errorOrNull =>
      switch (this) { Failure<T>(:final failure) => failure, _ => null };

  /// The payload when this is a success, otherwise null.
  ///
  /// Needed because `if (r is Success) r.data` does not promote a
  /// `Result<T>` to `Success<T>` — a bare `is Success` test constrains the
  /// type argument to `dynamic`, so the compiler keeps refusing `.data`.
  T? get dataOrNull =>
      switch (this) { Success<T>(:final data) => data, _ => null };

  bool get isSuccess => this is Success<T>;

  /// The complement of [isSuccess].
  ///
  /// Worth having explicitly: `!r.isSuccess` reads as a double negative at
  /// every failure site, and the failure branch is the one whose
  /// mis-typing hides bugs.
  bool get isFailure => this is Failure<T>;
}

final class Success<T> extends Result<T> {
  const Success(this.data);
  final T data;

  @override
  String toString() => 'Success($data)';
}

final class Failure<T> extends Result<T> {
  /// Wrap an existing reason with a new payload type.
  const Failure(this.failure);

  /// Build a reason directly, for the common case.
  ///
  /// Deliberately not `const`: Dart will not construct an inner object from a
  /// constructor parameter inside a const initializer ("Arguments of a
  /// constant creation must be constant expressions"), and the failure path is
  /// not hot enough for the lost allocation to matter.
  Failure.reason(
    FailureKind kind, {
    String message = '',
    int? statusCode,
    Object? cause,
    String? endpoint,
  }) : failure = AppFailure(
          kind,
          message: message,
          statusCode: statusCode,
          cause: cause,
          endpoint: endpoint,
        );

  final AppFailure failure;

  @override
  String toString() => 'Failure($failure)';
}

/// Why an operation failed. [kind] drives UI behaviour.
enum FailureKind {
  /// Device is offline / DNS failed.
  network,

  /// We reached a host but it never answered within budget.
  timeout,

  /// Credentials expired or are absent; the caller should re-authenticate.
  unauthorized,

  /// A captcha or step-up challenge must be solved before the call can succeed.
  challengeRequired,

  /// The server asked us to back off.
  rateLimited,

  /// Non-JSON body: most often a captive portal or an HTML error page.
  protocol,

  /// Server returned 5xx or otherwise indicates it is at fault.
  server,

  /// We could not parse a payload that claimed to be successful.
  invalidData,

  /// User-supplied input failed local validation.
  validation,

  /// An adapter is declared but not implemented for this build.
  unsupported,

  /// Anything we did not classify.
  unknown,
}

final class AppFailure implements Exception {
  const AppFailure(
    this.kind, {
    this.message = '',
    this.statusCode,
    this.cause,
    this.endpoint,
  });

  final FailureKind kind;
  final String message;
  final int? statusCode;
  final Object? cause;

  /// The endpoint that produced this, for diagnostics. Never shown raw to
  /// end users.
  final String? endpoint;

  /// Human-readable label. UI code should map this through localisation
  /// instead of showing this English default.
  String get displayLabel => switch (kind) {
        FailureKind.network => 'Network unavailable',
        FailureKind.timeout => 'Request timed out',
        FailureKind.unauthorized => 'Sign-in required',
        FailureKind.challengeRequired => 'Verification required',
        FailureKind.rateLimited => 'Too many requests',
        FailureKind.protocol => 'Unexpected response',
        FailureKind.server => 'Server error',
        FailureKind.invalidData => 'Could not read response',
        FailureKind.validation => 'Invalid input',
        FailureKind.unsupported => 'Not available in this build',
        FailureKind.unknown => 'Something went wrong',
      };

  @override
  String toString() => 'AppFailure(${kind.name}: $message'
      '${statusCode == null ? '' : ' [$statusCode]'}'
      '${endpoint == null ? '' : ' $endpoint'})';
}
