/// A client for Ham's public MCP service.
///
/// ## Why this exists
///
/// The 「给分」 feature is not something a student can read from the university.
/// It is built from contributions: Ham's own handbook says that **every time the
/// 给分 screen is opened, the app uploads the user's own marks (anonymised, keyed
/// by a derived value rather than the student number) to Ham's server**, and the
/// server aggregates them into score buckets per course and per instructor.
///
/// Ham publishes that aggregation as an MCP service:
///
/// ```
/// POST https://mcp.ham.nowcent.cn/mcp      Streamable HTTP
/// Authorization: Bearer <the user's own API key>
/// ```
///
/// The user generates that key at `https://ham.nowcent.cn/console/tokens`. It is
/// **their** credential, revocable by them, and it never leaves this process.
///
/// ## Why the tools are discovered rather than named
///
/// The backend that implements the scoring is **not public** — `ham-backend-go`
/// answers 404, as do `ham-ios`, `ham-android` and `ham-proto`. What *is* public
/// is the contract (`ham-open-proto/score.proto`) and the gateway's REST table,
/// and neither names the MCP tool identifiers.
///
/// So this client asks the server which tools it has and matches on meaning:
/// a tool whose name or description mentions scores/grades and whose input schema
/// mentions a course or instructor. Guessing an identifier would produce a client
/// that fails the day the server renames one — and it would look like the user's
/// key was wrong.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/result.dart';

/// One call's worth of state: the MCP session, protocol version, and request ids.
///
/// One instance is one conversation. The handshake is stateful (the server issues
/// a session id that later requests must echo), so sharing an instance between
/// unrelated queries is how a stale session gets reused.
class HamMcpClient {
  HamMcpClient({
    required this.apiKey,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// [V] The documented service address.
  static const String endpoint = 'https://mcp.ham.nowcent.cn/mcp';

  /// [V] The protocol revision this client speaks. Servers negotiate down.
  static const String protocolVersion = '2025-06-18';

  /// The user's own API key. **Never logged, never stored, never put in a
  /// message.** [toString] is overridden to keep it out of accidental output.
  final String apiKey;

  final http.Client _http;

  String? _sessionId;
  String _negotiatedVersion = protocolVersion;
  int _nextId = 1;
  bool _initialized = false;

  /// Whether the handshake has completed.
  bool get isInitialized => _initialized;

  /// Releases the underlying client.
  void close() => _http.close();

  // ---------------------------------------------------------------- discovery

  /// The tools the server offers.
  ///
  /// Called once per session and cached by the caller, not here: the list can
  /// change between deployments, and a stale cache would hide that.
  Future<Result<List<HamMcpTool>>> listTools() async {
    final ready = await _ensureInitialized();
    if (ready.isFailure) return Failure<List<HamMcpTool>>(ready.errorOrNull!);

    final rpc = await _rpc('tools/list', const <String, Object?>{});
    if (rpc.isFailure) return Failure<List<HamMcpTool>>(rpc.errorOrNull!);

    final raw = rpc.requireValue['tools'];
    if (raw is! List) {
      return Failure<List<HamMcpTool>>.reason(
        FailureKind.invalidData,
        message: 'The server answered tools/list without a tools array.',
        endpoint: endpoint,
      );
    }

    final tools = <HamMcpTool>[];
    for (final item in raw) {
      final t = HamMcpTool.tryParse(item);
      if (t != null) tools.add(t);
    }
    return Success(tools);
  }

  /// Calls a tool and returns its structured result.
  ///
  /// [arguments] is passed through untouched; the caller builds it from the
  /// chosen tool's own input schema.
  Future<Result<Object?>> callTool(
    String name, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    final ready = await _ensureInitialized();
    if (ready.isFailure) return Failure<Object?>(ready.errorOrNull!);

    final rpc = await _rpc('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    if (rpc.isFailure) return Failure<Object?>(rpc.errorOrNull!);

    final result = rpc.requireValue;
    // A tool-level failure arrives as `isError: true` with the text in content,
    // **not** as a JSON-RPC error — the call itself succeeded.
    if (result['isError'] == true) {
      return Failure<Object?>.reason(
        FailureKind.server,
        message: 'The Ham tool reported a failure: ${_contentText(result)}',
        endpoint: endpoint,
      );
    }
    return Success(_structured(result));
  }

  // ------------------------------------------------------------------ plumbing

  Future<Result<void>> _ensureInitialized() async {
    if (_initialized) return const Success(null);

    final rpc = await _rpc('initialize', {
      'protocolVersion': protocolVersion,
      'capabilities': const <String, Object?>{},
      'clientInfo': const {'name': 'campus-atlas', 'version': '0.1'},
    });
    if (rpc.isFailure) return Failure<void>(rpc.errorOrNull!);

    final negotiated = rpc.requireValue['protocolVersion'];
    if (negotiated is String && negotiated.isNotEmpty) {
      _negotiatedVersion = negotiated;
    }

    // The spec requires this notification before any other call. It has no id and
    // no reply, so a failure here is not fatal — some servers simply drop it.
    await _notify('notifications/initialized');

    _initialized = true;
    return const Success(null);
  }

  Future<Result<Map<String, Object?>>> _rpc(
    String method,
    Map<String, Object?> params,
  ) async {
    final id = _nextId++;
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });

    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse(endpoint),
            headers: _headers(),
            body: body,
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.timeout,
        message: 'The Ham service did not answer in time.',
        endpoint: endpoint,
      );
    } on http.ClientException catch (e) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.network,
        message: 'Could not reach the Ham service: ${e.message}',
        endpoint: endpoint,
      );
    }

    _absorbSession(response);

    if (response.statusCode == 401 || response.statusCode == 403) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.unauthorized,
        statusCode: response.statusCode,
        endpoint: endpoint,
        // Deliberately does not echo the key, even a prefix of it.
        message: 'Ham refused the API key. Generate a fresh one at '
            'ham.nowcent.cn/console/tokens and try again.',
      );
    }

    if (response.statusCode != 200) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.server,
        statusCode: response.statusCode,
        endpoint: endpoint,
        message: 'The Ham service answered HTTP ${response.statusCode}.',
      );
    }

    final envelope = _decodeEnvelope(response);
    if (envelope.isFailure) {
      return Failure<Map<String, Object?>>(envelope.errorOrNull!);
    }
    final map = envelope.requireValue;

    if (map['error'] is Map) {
      final err = map['error'] as Map;
      return Failure<Map<String, Object?>>.reason(
        FailureKind.server,
        message:
            'Ham returned an error: ${err['message'] ?? err['code'] ?? ''}',
        endpoint: endpoint,
      );
    }

    final result = map['result'];
    if (result is Map) {
      return Success(Map<String, Object?>.from(result));
    }
    // A result that is not an object is still a success for methods that return
    // nothing meaningful; callers that need fields will detect the absence.
    return Success(const <String, Object?>{});
  }

  Future<void> _notify(String method) async {
    try {
      await _http
          .post(
            Uri.parse(endpoint),
            headers: _headers(),
            body: jsonEncode({'jsonrpc': '2.0', 'method': method}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // A dropped notification is not worth failing a sign-in over.
    }
  }

  Map<String, String> _headers() => {
        'content-type': 'application/json',
        // Both are required by the streamable-HTTP transport: the server may
        // answer either way and will refuse a client that accepts only one.
        'accept': 'application/json, text/event-stream',
        'authorization': 'Bearer $apiKey',
        'mcp-protocol-version': _negotiatedVersion,
        if (_sessionId != null) 'mcp-session-id': _sessionId!,
      };

  void _absorbSession(http.Response response) {
    final id = response.headers['mcp-session-id'];
    if (id != null && id.isNotEmpty) _sessionId = id;
  }

  /// Reads a JSON-RPC envelope out of either a JSON body or an SSE stream.
  ///
  /// The transport allows both, and which one arrives is the server's choice per
  /// response — so a client that only parses JSON works until the day the server
  /// switches, and then reports a protocol error that looks like a server fault.
  Result<Map<String, Object?>> _decodeEnvelope(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    if (text.isEmpty) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.protocol,
        message: 'The Ham service answered with an empty body.',
        endpoint: endpoint,
      );
    }

    // JSON first: it is what a plain request returns.
    if (text.startsWith('{')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) return Success(Map<String, Object?>.from(decoded));
      } catch (_) {
        // Fall through to the stream reader.
      }
    }

    // SSE: `event: message` then one or more `data:` lines per event.
    final buffer = StringBuffer();
    for (final line in const LineSplitter().convert(text)) {
      if (line.startsWith('data:')) {
        buffer.write(line.substring(5).trimLeft());
      } else if (line.isEmpty && buffer.isNotEmpty) {
        final parsed = _tryJson(buffer.toString());
        if (parsed != null) return Success(parsed);
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) {
      final parsed = _tryJson(buffer.toString());
      if (parsed != null) return Success(parsed);
    }

    return Failure<Map<String, Object?>>.reason(
      FailureKind.protocol,
      message: 'Could not read a JSON-RPC message from the Ham response '
          '(${text.length} B).',
      endpoint: endpoint,
    );
  }

  static Map<String, Object?>? _tryJson(String s) {
    try {
      final decoded = jsonDecode(s);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// The machine-readable part of a tool result.
  ///
  /// MCP allows `structuredContent` for JSON, and always allows a `content` array
  /// of typed blocks. Both are read; whichever the server filled is used.
  static Object? _structured(Map<String, Object?> result) {
    final structured = result['structuredContent'];
    if (structured != null) return structured;

    final content = result['content'];
    if (content is List) {
      for (final block in content) {
        if (block is Map &&
            block['type'] == 'text' &&
            block['text'] is String) {
          final parsed = _tryJson(block['text'] as String);
          if (parsed != null) return parsed;
        }
      }
      // Nothing parseable: hand the text over so a caller can still show it.
      return _contentText(result);
    }
    return null;
  }

  static String _contentText(Map<String, Object?> result) {
    final content = result['content'];
    if (content is List) {
      final parts = <String>[];
      for (final block in content) {
        if (block is Map && block['text'] is String) {
          parts.add(block['text'] as String);
        }
      }
      if (parts.isNotEmpty) return parts.join('\n');
    }
    return '(no text)';
  }

  @override
  String toString() => 'HamMcpClient(session: ${_sessionId != null}, '
      'initialized: $_initialized)';
}

/// One tool as the server describes it.
class HamMcpTool {
  const HamMcpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;

  /// The JSON Schema of the arguments. Used to build a call rather than guess
  /// parameter names.
  final Map<String, Object?> inputSchema;

  static HamMcpTool? tryParse(Object? node) {
    if (node is! Map) return null;
    final name = node['name'];
    if (name is! String || name.isEmpty) return null;
    return HamMcpTool(
      name: name,
      description: '${node['description'] ?? ''}',
      inputSchema: node['inputSchema'] is Map
          ? Map<String, Object?>.from(node['inputSchema'] as Map)
          : const <String, Object?>{},
    );
  }

  /// The declared argument names, in schema order.
  List<String> get argumentNames {
    final props = inputSchema['properties'];
    if (props is Map) return props.keys.map((k) => '$k').toList();
    return const <String>[];
  }

  /// Whether this tool is the score lookup, judged by what it says it does.
  ///
  /// Matching on meaning rather than on an identifier: the backend is closed, so
  /// the only stable handle is the description. Both halves must agree — a tool
  /// that merely mentions scores in passing is not the score query.
  bool get looksLikeScoreLookup {
    final d = '$name $description'.toLowerCase();
    final mentionsScore = d.contains('score') ||
        d.contains('grade') ||
        d.contains('成绩') ||
        d.contains('给分');
    final mentionsSubject = d.contains('course') ||
        d.contains('instructor') ||
        d.contains('teacher') ||
        d.contains('课程') ||
        d.contains('教师') ||
        d.contains('授课');
    return mentionsScore && mentionsSubject;
  }

  /// Whether this tool resolves a fuzzy keyword to exact names.
  ///
  /// It is the lookup that makes 高等数学 work at all: Ham stores the course as
  /// 高等数学A…H, so the exact-name query finds nothing and the name has to be
  /// resolved first.
  ///
  /// The `keyword_type` argument is the discriminator, not the word "search".
  /// `get_course_grade_stats` says *"Search course grade statistics list by
  /// keyword"* and takes a `keyword` too, so a search-flavoured description and a
  /// `keyword` argument together match **both** tools — and the stats tool comes
  /// first in the list. Resolving against it returns `items` where a `hits` array
  /// was expected, which looks exactly like "this course does not exist".
  ///
  /// Only the lookup takes a *selector for what kind of thing the keyword is*.
  bool get looksLikeCourseSearch {
    final d = '$name $description'.toLowerCase();
    final args = argumentNames.map((n) => n.toLowerCase()).toList();
    final mentionsLookup = d.contains('look up') ||
        d.contains('lookup') ||
        d.contains('search') ||
        d.contains('搜索') ||
        d.contains('查找');
    return mentionsLookup &&
        args.contains('keyword') &&
        args.contains('keyword_type');
  }

  @override
  String toString() => 'HamMcpTool($name)';
}
