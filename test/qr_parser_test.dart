import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';
import 'package:test/test.dart';

String _freshHex() {
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${ts}abcdef0123456789abcdef0123456789'; // 10 + 32 = 42
}

void main() {
  group('extractQrData', () {
    test('URL 格式提取 hex', () {
      final hex = _freshHex();
      expect(hex.length, 42);
      final url = 'https://example.com/j?p=foo!3~$hex!4~bar';
      expect(extractQrData(url, now: DateTime.now()), hex);
    });

    test('纯 hex 也能识别', () {
      final hex = _freshHex();
      expect(extractQrData(hex, now: DateTime.now()), hex);
    });

    test('过期的 QR 数据返回空', () {
      final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 60;
      final hex = '${ts}abcdef0123456789abcdef0123456789';
      expect(extractQrData(hex, now: DateTime.now()), '');
    });

    test('非 hex 字符返回空', () {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final hex = '${ts}ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ';
      expect(extractQrData(hex, now: DateTime.now()), '');
    });

    test('长度不是 42 返回空', () {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final hex = '${ts}abcdef';
      expect(extractQrData(hex, now: DateTime.now()), '');
    });

    test('isValidQrData 与 extractQrData 一致', () {
      final hex = _freshHex();
      expect(isValidQrData(hex, now: DateTime.now()), isTrue);
      expect(isValidQrData('${DateTime.now().millisecondsSinceEpoch ~/ 1000}garbage',
          now: DateTime.now()),
          isFalse);
    });
  });
}
