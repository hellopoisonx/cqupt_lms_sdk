import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';
import 'package:test/test.dart';

/// 用线性同余实现的确定性 RNG，便于测试加密输出可重复。
class DeterministicRng implements Random {
  DeterministicRng(this.seed);
  int seed;

  @override
  bool nextBool() => nextInt(2) == 0;

  @override
  double nextDouble() => nextInt(0x7fffffff) / 0x7fffffff;

  @override
  int nextInt(int max) {
    final next = (seed * 1103515245 + 12345) & 0x7fffffff;
    seed = next;
    return next % max;
  }
}

void main() {
  group('normalizeAesKey', () {
    test('短于 16 字节补 0', () {
      final k = normalizeAesKey('abc');
      expect(k.length, 16);
      expect(k[0], 0x61);
      expect(k[2], 0x63);
      expect(k[3], 0);
      expect(k[15], 0);
    });

    test('长于 16 字节截断', () {
      final k = normalizeAesKey('abcdefghijklmnopqrstuvwxyz');
      expect(k.length, 16);
      expect(utf8.decode(k), 'abcdefghijklmnop');
    });

    test('正好 16 字节原样', () {
      const raw = 'abcdefghijklmnop';
      expect(utf8.decode(normalizeAesKey(raw)), raw);
    });
  });

  group('pkcs7Pad', () {
    test('刚好 blockSize 倍数时补一整个 block', () {
      final data = List<int>.filled(16, 0x41);
      final padded = pkcs7Pad(data, 16);
      expect(padded.length, 32);
      expect(padded.sublist(16).every((b) => b == 0x10), isTrue);
    });

    test('部分填充', () {
      final data = [0x41, 0x42, 0x43];
      final padded = pkcs7Pad(data, 8);
      expect(padded.length, 8);
      expect(padded.sublist(3).every((b) => b == 5), isTrue);
    });
  });

  group('encryptPassword', () {
    test('空 salt 时返回原密码', () {
      expect(encryptPassword('mypassword', ''), 'mypassword');
    });

    test('结果 url-decode 后是合法 base64', () {
      final out = encryptPassword('pwd', 'saltsaltsaltsalt',
          rng: DeterministicRng(42));
      final decoded = Uri.decodeComponent(out);
      expect(() => base64.decode(decoded), returnsNormally);
    });

    test('固定随机源产出可重复的密文', () {
      final a = encryptPassword('pwd', 'saltsaltsaltsalt',
          rng: DeterministicRng(7));
      final b = encryptPassword('pwd', 'saltsaltsaltsalt',
          rng: DeterministicRng(7));
      expect(a, equals(b));
    });

    test('不同随机源产出不同密文', () {
      final a = encryptPassword('pwd', 'saltsaltsaltsalt',
          rng: DeterministicRng(1));
      final b = encryptPassword('pwd', 'saltsaltsaltsalt',
          rng: DeterministicRng(2));
      expect(a, isNot(equals(b)));
    });
  });

  test('aesCbcEncrypt 16 字节输入经 PKCS#7 填充后产出 32 字节', () {
    final key = Uint8List(16);
    final iv = Uint8List(16);
    final padded = Uint8List.fromList(List.filled(16, 0x10));
    final out = aesCbcEncrypt(plaintext: padded, key: key, iv: iv);
    // PKCS#7 要求即使对齐到 blockSize 也要补一个完整块。
    expect(out.length, 32);
    // 改 IV 后密文必变
    final iv2 = Uint8List.fromList(List.generate(16, (i) => i + 1));
    final out2 = aesCbcEncrypt(plaintext: padded, key: key, iv: iv2);
    expect(out2, isNot(equals(out)));
  });
}
