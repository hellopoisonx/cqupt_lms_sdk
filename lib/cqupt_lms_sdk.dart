/// 重庆邮电大学统一身份认证 (CAS) + LMS 签到 Dart SDK。
///
/// 涵盖：
/// - **CAS 模块**：登录 IDS 拿到任意 service 的 ticket URL；
/// - **LMS 客户端**：登录、拉取活跃签到、提交签到（QR/数字/雷达）、签到详情；
/// - **辅助工具**：QR 数据解析、教学楼坐标匹配、课表 API；
/// - **Poller**：异步事件流 + 课表感知轮询 + 自动签到。
///
/// 所有公开 API 都是异步的（`Future` / `Stream`）。调用方可用
/// `await sdk.xxx()` 与 `sdk.events.listen(...)` 自由组合。
library;

export 'src/cas/captcha.dart';
export 'src/cas/cas_sdk.dart';
export 'src/cas/encryption.dart';
export 'src/cas/extractor.dart';
export 'src/cas/http_core.dart';
export 'src/curriculum/curriculum.dart';
export 'src/curriculum/curriculum_api.dart';
export 'src/exceptions.dart';
export 'src/http/no_redirect_client.dart';
export 'src/lms/lms_client.dart' show LmsClient, LmsConfig, LmsSession, Cookie;
export 'src/lms/models.dart';
export 'src/location/buildings.dart';
export 'src/poller/poller.dart';
export 'src/qr/qr_parser.dart';
