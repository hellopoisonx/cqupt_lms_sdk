/// 验证码求解器类型定义。
///
/// 典型实现：
///   - 人工输入：把图片落盘后在 UI 提示用户输入；
///   - 本地 OCR：调用 ddddocr / paddleocr 等；
///   - 远程打码平台：调云端 HTTP API。
///
/// 返回空字符串视为放弃，登录会因验证码错误而失败。
library;

import 'dart:typed_data';

/// 同步型验证码求解器。
///
/// 接收验证码图片字节流（通常为 JPEG），返回最终提交给 IDS 的字符串。
typedef CaptchaSolver = String Function(Uint8List image);

/// 异步型验证码求解器。
///
/// 在 [LmsClient] 等异步上下文里更易使用，避免在求解阶段阻塞事件循环。
typedef AsyncCaptchaSolver = Future<String> Function(Uint8List image);
