import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/network/api_client.dart';
import '../../core/result.dart';
import '../../core/storage/settings.dart';

/// A chat message, either direction.
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    this.createdAt,
  });

  final String role; // 'user' | 'assistant' | 'system'
  final String content;
  final DateTime? createdAt;

  Map<String, Object?> toJson() => {'role': role, 'content': content};
}

/// Client for any OpenAI-compatible `/chat/completions` endpoint.
///
/// This is deliberately provider-neutral: llama.cpp server, Ollama, vLLM,
/// LM Studio, OpenAI and most hosted gateways all speak this dialect, so the
/// user is not locked to a single vendor — and no API key is baked into the
/// binary.
class AiChatRepository {
  AiChatRepository({
    required this.client,
    required this.settings,
  });

  final ApiClient client;
  final AppSettings settings;

  /// Normalises a user-supplied base URL into a concrete endpoint.
  ///
  /// Accepts `https://host`, `https://host/v1`, or a full
  /// `.../chat/completions` URL, because people paste all three.
  static Uri? buildChatUri(String baseUrl) {
    var base = baseUrl.trim();
    if (base.isEmpty) return null;
    if (!base.contains('://')) base = 'https://$base';
    base = base.replaceAll(RegExp(r'/+$'), '');

    if (base.endsWith('/chat/completions') || base.endsWith('/completions')) {
      return Uri.tryParse(base);
    }
    return Uri.tryParse('$base/chat/completions');
  }

  /// Non-streaming send. Returns the assistant reply.
  Future<Result<ChatMessage>> send(
    List<ChatMessage> history, {
    String? systemPrompt,
  }) async {
    final endpoint = await settings.aiEndpoint();
    final uri = buildChatUri(endpoint.baseUrl);
    if (uri == null) {
      return Failure<ChatMessage>.reason(
        FailureKind.validation,
        message: 'Chat endpoint is not configured',
      );
    }

    final messages = <Map<String, String>>[
      if (systemPrompt != null && systemPrompt.isNotEmpty)
        {'role': 'system', 'content': systemPrompt},
      ...history.map((m) => {'role': m.role, 'content': m.content}),
    ];

    final body = <String, Object?>{
      'model': endpoint.model.isEmpty ? 'gpt-4o-mini' : endpoint.model,
      'messages': messages,
      'stream': false,
    };

    final raw = await client.postJson(
      uri,
      body: body,
      headers: {
        if (endpoint.apiKey.isNotEmpty)
          'authorization': 'Bearer ${endpoint.apiKey}',
      },
    );
    if (raw is Failure) return Failure<ChatMessage>(raw.errorOrNull!);

    final content = extractFirstAssistantText(raw.requireValue);
    if (content == null) {
      return Failure<ChatMessage>.reason(
        FailureKind.invalidData,
        message: 'Response contained no assistant message',
      );
    }
    return Success(ChatMessage(role: 'assistant', content: content));
  }

  /// Pulls `choices[0].message.content` out of a response, tolerating the
  /// small dialect differences between servers (some nest content in a list
  /// of typed parts).
  static String? extractFirstAssistantText(Map<String, Object?> payload) {
    final choices = payload['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map<String, Object?>) return null;

    final message = first['message'];
    if (message is Map<String, Object?>) {
      final content = message['content'];
      if (content is String) return content;
      if (content is List) {
        final buffer = StringBuffer();
        for (final part in content) {
          if (part is Map<String, Object?> && part['text'] is String) {
            buffer.write(part['text']);
          }
        }
        final text = buffer.toString();
        if (text.isNotEmpty) return text;
      }
    }
    // Some `/completions`-style servers answer with `text` directly.
    final text = first['text'];
    if (text is String && text.isNotEmpty) return text;
    return null;
  }

  /// Streaming send. Emits incremental text deltas.
  ///
  /// Uses a chunked HTTP response and parses `data:` lines from
  /// `text/event-stream`. [onDelta] is invoked once per content delta;
  /// the future completes when the server closes the stream.
  Future<Result<ChatMessage>> sendStream(
    List<ChatMessage> history, {
    String? systemPrompt,
    required void Function(String delta) onDelta,
    void Function()? onDone,
  }) async {
    final endpoint = await settings.aiEndpoint();
    final uri = buildChatUri(endpoint.baseUrl);
    if (uri == null) {
      return Failure<ChatMessage>.reason(
        FailureKind.validation,
        message: 'Chat endpoint is not configured',
      );
    }

    final messages = <Map<String, String>>[
      if (systemPrompt != null && systemPrompt.isNotEmpty)
        {'role': 'system', 'content': systemPrompt},
      ...history.map((m) => {'role': m.role, 'content': m.content}),
    ];

    final body = <String, Object?>{
      'model': endpoint.model.isEmpty ? 'gpt-4o-mini' : endpoint.model,
      'messages': messages,
      'stream': true,
    };

    try {
      final request = http.Request('POST', uri)
        ..headers.addAll({
          'content-type': 'application/json',
          'accept': 'text/event-stream',
          'user-agent': AppConfigUserAgent.value,
          if (endpoint.apiKey.isNotEmpty)
            'authorization': 'Bearer ${endpoint.apiKey}',
        })
        ..body = jsonEncode(body);

      final streamed = await client.rawSend(request);
      if (streamed is Failure) {
        return Failure<ChatMessage>(streamed.errorOrNull!);
      }

      final buffer = StringBuffer();
      final accumulated = StringBuffer();

      await for (final chunk in streamed.requireValue.stream) {
        buffer.write(chunk);
        var text = buffer.toString();
        final lines = text.split('\n');
        // Keep the tail: an SSE event may straddle two chunks.
        text = lines.isNotEmpty ? lines.removeLast() : '';
        buffer
          ..clear()
          ..write(text);

        for (final line in lines) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          final payload = trimmed.substring(5).trim();
          if (payload.isEmpty || payload == '[DONE]') continue;

          final delta = extractStreamDelta(payload);
          if (delta != null && delta.isNotEmpty) {
            accumulated.write(delta);
            onDelta(delta);
          }
        }
      }

      onDone?.call();
      final result = accumulated.toString();
      if (result.isEmpty) {
        return Failure<ChatMessage>.reason(
          FailureKind.invalidData,
          message: 'Stream ended without any content',
        );
      }
      return Success(ChatMessage(role: 'assistant', content: result));
    } on TimeoutException catch (e) {
      return Failure<ChatMessage>.reason(
        FailureKind.timeout,
        message: 'Stream timed out',
        cause: e,
      );
    } catch (e) {
      return Failure<ChatMessage>.reason(
        FailureKind.network,
        message: e.toString(),
        cause: e,
      );
    }
  }

  /// Parses one SSE `data:` payload for a delta.
  static String? extractStreamDelta(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, Object?>) return null;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final first = choices.first;
      if (first is! Map<String, Object?>) return null;

      final delta = first['delta'];
      if (delta is Map<String, Object?> && delta['content'] is String) {
        return delta['content']! as String;
      }
      final text = first['text'];
      return text is String ? text : null;
    } on FormatException {
      return null;
    }
  }

  /// Lists models from `<base>/models`, for the endpoint picker.
  Future<Result<List<String>>> listModels() async {
    final endpoint = await settings.aiEndpoint();
    final base = endpoint.baseUrl.trim();
    if (base.isEmpty) {
      return Failure<List<String>>.reason(
        FailureKind.validation,
        message: 'Endpoint not configured',
      );
    }
    var normalized = base;
    if (!normalized.contains('://')) normalized = 'https://$normalized';
    normalized = normalized.replaceAll(RegExp(r'/+$'), '');
    // Strip a trailing /chat/completions so /models resolves against the API
    // root rather than against the completions path.
    normalized = normalized.replaceAll(RegExp(r'/chat/completions$'), '');

    final uri = Uri.tryParse('$normalized/models');
    if (uri == null) {
      return Failure<List<String>>.reason(
        FailureKind.validation,
        message: 'Could not build models URL',
      );
    }

    final raw = await client.getJson(
      uri,
      headers: {
        if (endpoint.apiKey.isNotEmpty)
          'authorization': 'Bearer ${endpoint.apiKey}',
      },
    );
    if (raw is Failure) return Failure<List<String>>(raw.errorOrNull!);

    final data = raw.requireValue['data'];
    if (data is! List) {
      return Failure<List<String>>.reason(
        FailureKind.invalidData,
        message: 'models response missing data[]',
      );
    }
    final ids = <String>[];
    for (final item in data) {
      if (item is Map<String, Object?> && item['id'] is String) {
        ids.add(item['id']! as String);
      }
    }
    return Success(ids);
  }

  /// Cheap connectivity probe: one tiny round trip.
  Future<Result<bool>> checkConnection() async {
    final models = await listModels();
    if (models is Success) return const Success(true);
    // Some gateways don't expose /models but do serve chat — retry with a
    // minimal completion rather than reporting a false negative.
    final probe = await send(const [
      ChatMessage(role: 'user', content: 'ping'),
    ]);
    if (probe is Success) return const Success(true);
    // Propagate whichever probe failed rather than flattening it to a bare
    // boolean, so the settings screen can show the real reason.
    return Failure<bool>(
      models is Failure
          ? models.errorOrNull!
          : const AppFailure(FailureKind.unknown),
    );
  }
}

/// Tiny constant holder so the streaming path matches [ApiClient]'s identity
/// without importing the whole config file twice.
abstract final class AppConfigUserAgent {
  static const String value = 'campus-atlas/0.1 (+open-source)';
}
