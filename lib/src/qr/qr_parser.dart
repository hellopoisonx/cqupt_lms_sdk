/// QR 签到数据解析工具。
///
/// 支持两种格式：
///   - 纯 42 位 hex（10 位时间戳 + 32 位随机）；
///   - URL 格式 `/j?p=...!3~<hex>!4~...`，自动提取中间的 hex。
///
/// 返回的 hex 必须在 15 秒内生成（与服务端校验窗口一致）。
library;

const _qrHexRe = r'^[a-f0-9]{42}$';
final RegExp _qrDataRegexp = RegExp(_qrHexRe, caseSensitive: false);
final RegExp _qrUrlRegexp = RegExp(r'!3~([a-fA-F0-9]+)');

/// 从原始 QR 字符串中提取 42 位 hex。
///
/// 返回空字符串表示无法解析或已过期。
String extractQrData(String rawData, {DateTime? now}) {
  var data = rawData;
  // 1. URL 格式：从 `!3~<hex>!4~` 提取
  if (data.startsWith('/j?p=') || data.contains('!3~')) {
    final m = _qrUrlRegexp.firstMatch(data);
    if (m == null) return '';
    data = m.group(1) ?? '';
  }
  // 2. 校验 42 位 hex
  data = data.toLowerCase();
  if (!_qrDataRegexp.hasMatch(data)) return '';
  // 3. 校验时间戳（10 位 unix 秒）
  final ts = int.tryParse(data.substring(0, 10));
  if (ts == null) return '';
  final checkTime = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  if (checkTime - ts > 15) return '';
  return data;
}

/// 是否为合法的未过期 QR 数据。
bool isValidQrData(String rawData, {DateTime? now}) =>
    extractQrData(rawData, now: now).isNotEmpty;
