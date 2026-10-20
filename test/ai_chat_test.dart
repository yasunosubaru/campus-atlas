import 'package:campus_atlas/features/ai_chat/ai_chat_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildChatUri', () {
    test('appends the endpoint to a bare base URL', () {
      expect(
        AiChatRepository.buildChatUri('https://api.example.test'),
        Uri.parse('https://api.example.test/chat/completions'),
      );
    });

    test('keeps a /v1 prefix intact', () {
      expect(
        AiChatRepository.buildChatUri('https://api.example.test/v1'),
        Uri.parse('https://api.example.test/v1/chat/completions'),
      );
    });

    test('leaves an already-complete URL alone', () {
      expect(
        AiChatRepository.buildChatUri(
            'https://api.example.test/v1/chat/completions'),
        Uri.parse('https://api.example.test/v1/chat/completions'),
      );
    });

    test('accepts a bare completions path', () {
      expect(
        AiChatRepository.buildChatUri('https://h.test/completions'),
        Uri.parse('https://h.test/completions'),
      );
    });

    test('supplies https when the scheme is missing', () {
      expect(
        AiChatRepository.buildChatUri('api.example.test'),
        Uri.parse('https://api.example.test/chat/completions'),
      );
    });

    test('strips a trailing slash', () {
      expect(
        AiChatRepository.buildChatUri('https://api.example.test/'),
        Uri.parse('https://api.example.test/chat/completions'),
      );
    });

    test('returns null for an empty configuration', () {
      expect(AiChatRepository.buildChatUri(''), isNull);
      expect(AiChatRepository.buildChatUri('   '), isNull);
    });
  });

  group('extractFirstAssistantText', () {
    test('reads a plain string content', () {
      expect(
        AiChatRepository.extractFirstAssistantText(const {
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'hello'}
            }
          ]
        }),
        'hello',
      );
    });

    test('concatenates typed content parts', () {
      expect(
        AiChatRepository.extractFirstAssistantText(const {
          'choices': [
            {
              'message': {
                'content': [
                  {'type': 'text', 'text': 'part one '},
                  {'type': 'text', 'text': 'part two'},
                ]
              }
            }
          ]
        }),
        'part one part two',
      );
    });

    test('falls back to the completions-style text field', () {
      expect(
        AiChatRepository.extractFirstAssistantText(const {
          'choices': [
            {'text': 'legacy reply'}
          ]
        }),
        'legacy reply',
      );
    });

    test('returns null when there are no choices', () {
      expect(
        AiChatRepository.extractFirstAssistantText(const {'choices': []}),
        isNull,
      );
      expect(
        AiChatRepository.extractFirstAssistantText(const {}),
        isNull,
      );
    });
  });

  group('extractStreamDelta', () {
    test('reads delta.content', () {
      expect(
        AiChatRepository.extractStreamDelta(
          '{"choices":[{"delta":{"content":"Hi"}}]}',
        ),
        'Hi',
      );
    });

    test('returns null for a done marker', () {
      expect(AiChatRepository.extractStreamDelta('[DONE]'), isNull);
    });

    test('returns null for malformed payloads instead of throwing', () {
      expect(AiChatRepository.extractStreamDelta('not json'), isNull);
      expect(AiChatRepository.extractStreamDelta('{"choices":[]}'), isNull);
      expect(AiChatRepository.extractStreamDelta('[]'), isNull);
    });

    test('reads the completions-style text field when no delta exists', () {
      expect(
        AiChatRepository.extractStreamDelta(
          '{"choices":[{"text":"legacy"}]}',
        ),
        'legacy',
      );
    });
  });
}
