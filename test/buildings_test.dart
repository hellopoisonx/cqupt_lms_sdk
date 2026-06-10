import 'dart:math';

import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('getLocationCoords', () {
    test('4 位数字教室号命中教学楼', () {
      // 固定随机源：抖动不会改变位数
      final r = _ZeroRng();
      // 2306 => '2' 教学楼
      final c = getLocationCoords('2306', rng: r);
      expect(c, isNotNull);
      expect(c!.lat, closeTo(29.532345, 0.001));
      expect(c.lon, closeTo(106.606620, 0.001));
    });

    test('4 位但首字符未知返回 null', () {
      // '7' 教学楼不在表里
      expect(getLocationCoords('7123', rng: _ZeroRng()), isNull);
    });

    test('关键字命中综合实验楼 A', () {
      final c = getLocationCoords('综合实验楼A305', rng: _ZeroRng());
      expect(c, isNotNull);
      expect(c!.lat, closeTo(29.525598, 0.001));
      expect(c.lon, closeTo(106.605528, 0.001));
    });

    test('关键字命中篮球场', () {
      final c = getLocationCoords('桂花篮球场南', rng: _ZeroRng());
      expect(c, isNotNull);
      expect(c!.lat, closeTo(29.530162, 0.001));
    });

    test('空串返回 null', () {
      expect(getLocationCoords('', rng: _ZeroRng()), isNull);
    });

    test('未识别地点返回 null', () {
      expect(getLocationCoords('校外某处', rng: _ZeroRng()), isNull);
    });

    test('抖动不改变坐标量级', () {
      final r = Random();
      for (var i = 0; i < 20; i++) {
        final c = getLocationCoords('2306', rng: r);
        expect(c, isNotNull);
        expect(c!.lat, closeTo(29.532345, 0.01));
        expect(c.lon, closeTo(106.606620, 0.01));
      }
    });
  });
}

class _ZeroRng implements Random {
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
  @override
  int nextInt(int max) => 0;
}
