/// Drives the browser the Windows runner hosts for us.
///
/// ## Why the browser lives in the runner
///
/// Because a Flutter platform view does not work here. The app tried
/// `flutter_inappwebview` first: in a **release** build the window went
/// uniformly dark, the WebView2 process never composited, and no Dart exception
/// was raised — the page loaded (its own cache directory showed it) and nothing
/// reached the screen. Debug and profile were fine, which is what made it look
/// like an app bug for a while.
///
/// The runner now creates WebView2 against its own window handle. WebView2 draws
/// itself in a child window of that handle, so it never passes through the
/// engine's platform-view compositing and that failure cannot occur.
///
/// ## What it is for
///
/// Pages that require a person: the academic system gates its grade query behind
/// an anti-bot puzzle, and a session established inside the browser is the only
/// way to answer it. This class is how the app shows that page and reads the
/// reply — it never answers the puzzle itself.
///
/// Windows only. On other platforms [isSupported] is false and the caller is
/// expected to say so rather than showing a blank rectangle.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class NativeWebView {
  NativeWebView();

  static const MethodChannel _channel = MethodChannel('campus_atlas/webview');

  /// Page load results, script replies, and failures, in arrival order.
  final StreamController<NativeWebViewEvent> _events =
      StreamController<NativeWebViewEvent>.broadcast(sync: true);

  Stream<NativeWebViewEvent> get events => _events.stream;

  bool _attached = false;

  /// Whether this host provides the browser at all.
  ///
  /// Only Windows: the host lives in `windows/runner`, and the other platforms
  /// have no implementation. A caller must check this rather than open a blank
  /// rectangle and leave the person wondering.
  static bool get isSupported => Platform.isWindows;

  /// Starts listening. Safe to call more than once.
  void attach() {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'shown':
          _events.add(const NativeWebViewEvent(NativeWebViewEventKind.shown));
        case 'hidden':
          _events.add(const NativeWebViewEvent(NativeWebViewEventKind.hidden));
        case 'failed':
          _events.add(NativeWebViewEvent(
            NativeWebViewEventKind.failed,
            message: '${call.arguments}',
          ));
        case 'scriptResult':
          _events.add(NativeWebViewEvent(
            NativeWebViewEventKind.scriptResult,
            result: call.arguments is String ? call.arguments as String : null,
          ));
      }
    });
  }

  /// Shows [url], covering the window's client area.
  Future<void> open(String url) async {
    attach();
    await _channel.invokeMethod<void>('open', {'url': url});
  }

  /// Shows the browser again, without navigating.
  ///
  /// Needed because the browser is a native child window stacked **above** the
  /// Flutter view: anything Flutter draws below the reserved strip is behind it.
  /// A result therefore has to be shown with the browser hidden, and this is the
  /// way back. Re-`open`ing would navigate, losing the page the person got to.
  Future<void> show() async {
    await _channel.invokeMethod<void>('show');
  }

  /// Hides the browser. The page keeps running; call again to bring it back.
  Future<void> close() async {
    await _channel.invokeMethod<void>('close');
  }

  /// Re-lays the browser over the client area, e.g. after the window resized.
  Future<void> resize() async {
    await _channel.invokeMethod<void>('resize');
  }

  /// Runs [script] in the page. The reply arrives on [events] as
  /// [NativeWebViewEventKind.scriptResult], JSON-encoded by WebView2.
  ///
  /// WebView2 answers with the script's value serialised to JSON, so a script
  /// that returns a string arrives quoted and has to be decoded by the caller.
  Future<void> eval(String script) async {
    await _channel.invokeMethod<void>('eval', {'script': script});
  }

  /// Runs [script] and waits for its value.
  ///
  /// WebView2 answers with the script's value serialised to JSON, so a script that
  /// returns a string arrives quoted. That is why this decodes twice: the outer
  /// decode is WebView2's envelope, the inner one is the script's own JSON.
  ///
  /// **One eval at a time.** The host reports results without correlating them, so
  /// a second concurrent call would take the first one's answer.
  Future<Object?> evalJson(String script) async {
    attach();
    final completer = Completer<Object?>();
    late final StreamSubscription<NativeWebViewEvent> sub;

    sub = _events.stream.listen((event) {
      if (event.kind != NativeWebViewEventKind.scriptResult) return;
      if (completer.isCompleted) return;
      final raw = event.result;
      if (raw == null) {
        completer.complete(null);
        return;
      }
      try {
        final once = jsonDecode(raw);
        completer.complete(once is String ? jsonDecode(once) : once);
      } catch (_) {
        completer.complete(raw);
      }
    });

    try {
      await eval(script);
      return await completer.future.timeout(
        const Duration(seconds: 30),
        // Distinguishable from a script that answered, and from one that
        // answered with nothing: the three have different causes.
        onTimeout: () => <String, Object?>{'error': 'no script result in 30s'},
      );
    } finally {
      await sub.cancel();
    }
  }

  /// The cookies the browser currently holds for [urls].
  ///
  /// **[urls] is a list, and that is the whole point.** WebView2 matches cookies
  /// on the **path** as well as the host, so no single URL sees them all: the CAS
  /// grant is scoped to `https://cas.whu.edu.cn/authserver/` while a service
  /// session is scoped to the property's own root, and asking for one does not
  /// return the other. A harvest that asked for only one would report a perfectly
  /// good sign-in as missing its ticket — a bug this project has already shipped
  /// once (see [CasOrigin.authserverRoot]).
  ///
  /// Duplicates across URLs are removed by the host. **The values are sign-in
  /// credentials**: never log them, never put them in error text.
  Future<List<BrowserCookie>> cookies(List<String> urls) async {
    attach();
    final raw = await _channel.invokeMethod<List<Object?>>(
      'cookies',
      <String, Object?>{'urls': urls},
    );

    final out = <BrowserCookie>[];
    for (final entry in raw ?? const <Object?>[]) {
      if (entry is! Map) continue;
      out.add(BrowserCookie(
        name: '${entry['name'] ?? ''}',
        value: '${entry['value'] ?? ''}',
        domain: '${entry['domain'] ?? ''}',
        path: '${entry['path'] ?? ''}',
      ));
    }
    return out;
  }

  /// Releases the event stream. Synchronous so it can be called from a
  /// `State.dispose`, which cannot await.
  void dispose() {
    _channel.setMethodCallHandler(null);
    _events.close();
  }
}

enum NativeWebViewEventKind { shown, hidden, failed, scriptResult }

class NativeWebViewEvent {
  const NativeWebViewEvent(this.kind, {this.message, this.result});

  final NativeWebViewEventKind kind;
  final String? message;
  final String? result;

  @override
  String toString() =>
      'NativeWebViewEvent(${kind.name}${message == null ? '' : ' · $message'})';
}

/// One cookie, as the browser holds it.
///
/// **The value is a sign-in credential.** It is carried to the session and
/// nowhere else: not logged, not displayed, not written to disk.
class BrowserCookie {
  const BrowserCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
  });

  final String name;
  final String value;
  final String domain;
  final String path;

  /// Deliberately omits [value]: a debug print of this object must not put a
  /// live credential into a log.
  @override
  String toString() => 'BrowserCookie($name @ $domain$path)';
}
