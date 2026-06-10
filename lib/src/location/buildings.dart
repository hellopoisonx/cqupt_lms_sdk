/// CQUPT 校内坐标 / 教学楼匹配。
///
/// 完全复刻 rollcall-go 内部 `edge/location.go`：
///   - 4 位数字教室号首字符 = 教学楼编号；
///   - 关键字匹配到「综合实验楼 A/B/C」与运动场；
///   - 命中后坐标加 ±20m 随机抖动（服务端允许误差范围内）。
library;

import 'dart:math';

/// 经纬度坐标。
class Coordinate {
  const Coordinate(this.lat, this.lon);

  /// 纬度（GCJ-02）。
  final double lat;

  /// 经度（GCJ-02）。
  final double lon;

  @override
  String toString() => 'Coordinate(lat=$lat, lon=$lon)';
}

/// CQUPT 教学楼对应坐标（GCJ-02）。
const Map<String, Coordinate> teachingBuildings = {
  '1': Coordinate(29.531049, 106.605647),
  '2': Coordinate(29.532345, 106.606620),
  '3': Coordinate(29.535101, 106.609243),
  '4': Coordinate(29.536307, 106.609269),
  '5': Coordinate(29.536018, 106.610354),
  '8': Coordinate(29.534461, 106.611013),
  '9': Coordinate(29.525971, 106.606189),
};

/// 关键字匹配型建筑（如运动场、综合实验楼）。
class NamedBuilding {
  const NamedBuilding(this.keyword, this.lat, this.lon);
  final String keyword;
  final double lat;
  final double lon;
}

const List<NamedBuilding> otherBuildings = [
  NamedBuilding('综合实验楼A', 29.525598, 106.605528),
  NamedBuilding('综合实验楼B', 29.525013, 106.605611),
  NamedBuilding('综合实验楼C', 29.524309, 106.605629),
  NamedBuilding('桂花篮球场', 29.530162, 106.607208),
  NamedBuilding('灯光篮球场', 29.532465, 106.608514),
  NamedBuilding('风华运动场', 29.532786, 106.607568),
  NamedBuilding('太极运动场', 29.532896, 106.609731),
  NamedBuilding('乒乓球馆', 29.532465, 106.608514),
];

/// 把教学楼基础坐标加上 ±20m 随机抖动。
Coordinate _applyJitter(double lat, double lon, Random rng) {
  final jitterLat = (rng.nextDouble() - 0.2) * 0.0008;
  final jitterLon = (rng.nextDouble() - 0.2) * 0.0008;
  return Coordinate(lat + jitterLat, lon + jitterLon);
}

/// 给定地点名，返回（带抖动的）签到坐标。
///
/// 返回 `null` 表示无法识别。
Coordinate? getLocationCoords(String locationName, {Random? rng}) {
  if (locationName.isEmpty) return null;
  final r = rng ?? Random();

  // 1. 4 位数字教室号
  if (locationName.length == 4 && _isAllDigits(locationName)) {
    final base = teachingBuildings[locationName[0]];
    if (base != null) return _applyJitter(base.lat, base.lon, r);
  }

  // 2. 关键字匹配
  for (final b in otherBuildings) {
    if (locationName.contains(b.keyword)) {
      return _applyJitter(b.lat, b.lon, r);
    }
  }
  return null;
}

bool _isAllDigits(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return false;
  }
  return true;
}
