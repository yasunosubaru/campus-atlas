import 'package:campus_atlas/features/teaching_eval/ugsqs_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UgsqsRepository.resolveForwardUrl', () {
    test('keeps an absolute http(s) URL', () {
      expect(
        UgsqsRepository.resolveForwardUrl(
          'https://ugsqs.whu.edu.cn/eval/index?token=abc',
        ).toString(),
        'https://ugsqs.whu.edu.cn/eval/index?token=abc',
      );
    });

    test('resolves a root-relative URL against the host', () {
      expect(
        UgsqsRepository.resolveForwardUrl('/eval/index?token=abc').toString(),
        'https://ugsqs.whu.edu.cn/eval/index?token=abc',
      );
    });

    test('resolves a protocol-relative URL against the host', () {
      expect(
        UgsqsRepository.resolveForwardUrl('//ugsqs.whu.edu.cn/eval/index')
            .toString(),
        'https://ugsqs.whu.edu.cn/eval/index',
      );
    });

    test('refuses a non-http scheme or empty value', () {
      expect(UgsqsRepository.resolveForwardUrl('javascript:alert(1)'), isNull);
      expect(UgsqsRepository.resolveForwardUrl('   '), isNull);
    });
  });
}
