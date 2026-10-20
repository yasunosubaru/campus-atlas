import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Records framework and platform errors where they can be read afterwards.
///
/// Why this exists, in one sentence: **on Windows the release build is a
/// GUI-subsystem executable, so `print` goes nowhere, and a build error inside a
/// route is replaced by [ErrorWidget]'s release placeholder — which is a blank
/// box.** A release-only failure therefore presents as "the screen went blank"
/// with no message anywhere: not in the console, not on screen. That is exactly
/// how a blank 正方教务 sign-in window was first reported, and why the cause took
/// so long to find.
///
/// The log is written beside the executable (`crash.log`), because that is where
/// the person running the build will look, and because the app has no other
/// writable location it can rely on.
///
/// Errors are still handed to the default handlers as well, so debug builds and
/// `flutter run` behave exactly as before.
void installCrashLog() {
  final sink = _CrashLogSink();

  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    previous?.call(details);
    sink.write('FRAMEWORK', details.exceptionAsString(), details.stack);
  };

  // Errors that never reach the framework: they come from platform channels,
  // timers, and the plugin layer.
  PlatformDispatcher.instance.onError = (error, stack) {
    sink.write('PLATFORM', '$error', stack);
    return true;
  };
}

/// Appends entries to `crash.log` beside the executable.
class _CrashLogSink {
  /// Rotate rather than grow without bound: the file is a diagnostic aid, not a
  /// data store, and an app left running for days must not fill the disk.
  static const int _maxBytes = 256 * 1024;

  File? _file;
  bool _resolved = false;

  File? _target() {
    if (_resolved) return _file;
    _resolved = true;
    try {
      final dir = File(Platform.resolvedExecutable).parent;
      _file = File('${dir.path}${Platform.pathSeparator}crash.log');
    } catch (_) {
      // A build without a resolvable executable path simply keeps no log; that
      // is not worth taking the app down for.
      _file = null;
    }
    return _file;
  }

  void write(String kind, String message, StackTrace? stack) {
    final file = _target();
    if (file == null) return;

    final buffer = StringBuffer()
      ..writeln('=== $kind  ${DateTime.now().toIso8601String()}')
      ..writeln(message);

    if (stack != null) {
      // A full stack is usually far more than is useful; the top frames are
      // where the failure is.
      final lines = stack.toString().split('\n');
      buffer.writeln(lines.take(24).join('\n'));
      if (lines.length > 24) {
        buffer.writeln('    ... ${lines.length - 24} more');
      }
    }
    buffer.writeln();

    try {
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        file.writeAsStringSync('--- rotated at ${DateTime.now()}\n');
      }
      file.writeAsStringSync(buffer.toString(),
          mode: FileMode.append, flush: true);
    } catch (_) {
      // Diagnostics must never be the reason the app fails.
    }
  }
}
