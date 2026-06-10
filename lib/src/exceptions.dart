/// cqupt_lms_sdk 异常类型集合
library;

/// SDK 基础异常。
class SdkException implements Exception {
  /// 人类可读的错误描述。
  final String message;

  /// 可选底层异常。
  final Object? cause;

  const SdkException(this.message, [this.cause]);

  @override
  String toString() {
    if (cause == null) return 'SdkException: $message';
    return 'SdkException: $message (cause: $cause)';
  }
}

/// HTTP 请求错误（DNS 失败、连接被拒、超时等非业务错误）。
class HttpFailureException extends SdkException {
  const HttpFailureException(super.message, [super.cause]);
}

/// 业务响应非 2xx 状态码时抛出。
class HttpStatusException extends SdkException {
  /// 实际响应状态码。
  final int statusCode;

  /// 响应体（已尝试 UTF-8 解码）。
  final String body;

  HttpStatusException(this.statusCode, this.body)
      : super('HTTP $statusCode: ${body.length > 200 ? '${body.substring(0, 200)}...' : body}');
}

/// IDS 要求图形验证码，但未注册 [CaptchaSolver]。
class CaptchaRequiredException extends SdkException {
  const CaptchaRequiredException() : super('IDS 要求图形验证码，但未提供 CaptchaSolver');
}

/// 验证码求解器返回空字符串。
class CaptchaSolveException extends SdkException {
  const CaptchaSolveException() : super('CaptchaSolver 返回空字符串');
}

/// 登录失败（缺少 session cookie / 最终响应非预期）。
class LoginFailedException extends SdkException {
  const LoginFailedException(super.message, [super.cause]);
}

/// 签到请求返回的 `error_code` / `message` 字段。
class CheckinErrorException extends SdkException {
  /// 服务端下发的错误码。
  final String errorCode;

  const CheckinErrorException(this.errorCode) : super('签到失败: $errorCode');
}

/// QR 字符串无法解析为有效数据。
class InvalidQrDataException extends SdkException {
  const InvalidQrDataException() : super('无效或过期的 QR 数据');
}

/// Poller 已在运行。
class PollerAlreadyRunningException extends SdkException {
  const PollerAlreadyRunningException() : super('Poller 已经在运行');
}
