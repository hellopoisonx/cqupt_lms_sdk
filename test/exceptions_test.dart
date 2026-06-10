import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('SdkException 包含 cause', () {
    final e = SdkException('boom', StateError('inner'));
    expect(e.message, 'boom');
    expect(e.cause, isA<StateError>());
    expect(e.toString(), contains('boom'));
  });

  test('HttpStatusException 显示状态码和截断 body', () {
    final body = 'x' * 300;
    final e = HttpStatusException(500, body);
    expect(e.statusCode, 500);
    expect(e.body, body);
    expect(e.toString(), contains('500'));
    // body 超长时 toString 仅截断，不修改 body 字段本身
    expect(e.toString().length, lessThan(500));
  });

  test('CheckinErrorException 携带错误码', () {
    final e = CheckinErrorException('ERR_OUT_OF_RANGE');
    expect(e.errorCode, 'ERR_OUT_OF_RANGE');
    expect(e.toString(), contains('ERR_OUT_OF_RANGE'));
  });

  test('特定子异常消息', () {
    expect(const CaptchaRequiredException().toString(),
        contains('CaptchaSolver'));
    expect(const CaptchaSolveException().toString(), contains('空字符串'));
    expect(const InvalidQrDataException().toString(), contains('QR'));
    expect(const PollerAlreadyRunningException().toString(), contains('Poller'));
  });
}
