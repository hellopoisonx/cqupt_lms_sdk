import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('extractInputValue', () {
    test('提取单引号 / 双引号 value', () {
      const html = '''
        <html><body>
          <input id="pwdEncryptSalt" name="pwdEncryptSalt" value="abc123" />
          <input name='execution' value='exec-xyz' />
        </body></html>
      ''';
      expect(
        extractInputValue(html, ['id="pwdEncryptSalt"']),
        'abc123',
      );
      expect(
        extractInputValue(html, ['name="execution"']),
        'exec-xyz',
      );
    });

    test('多属性交集匹配（必须同时包含）', () {
      const html = '''
        <input id="execution" name="execution" value="real-exec" />
        <input name="execution" value="wrong-exec" />
      ''';
      expect(
        extractInputValue(html, ['id="execution"', 'name="execution"']),
        'real-exec',
      );
    });

    test('未找到返回空串', () {
      const html = '<input name="foo" value="bar" />';
      expect(extractInputValue(html, ['id="execution"']), '');
    });

    test('空 value 也能取到', () {
      const html = '<input id="pwdEncryptSalt" value="" />';
      expect(extractInputValue(html, ['id="pwdEncryptSalt"']), '');
    });
  });

  group('extractFormAction', () {
    test('id 在 action 前', () {
      const html = '<form id="pwdFromId" action="/authserver/login">...</form>';
      expect(extractFormAction(html, 'pwdFromId'), '/authserver/login');
    });

    test('action 在 id 前也能解析', () {
      const html = '<form action="/login" id="casLoginForm"></form>';
      expect(extractFormAction(html, 'casLoginForm'), '/login');
    });

    test('未找到返回空', () {
      const html = '<form id="other" action="/x"></form>';
      expect(extractFormAction(html, 'pwdFromId'), '');
    });
  });

  group('extractAnyFormAction', () {
    test('按顺序返回第一个非空 action', () {
      const html = '<form id="casLoginForm" action="/second"></form>';
      expect(
        extractAnyFormAction(html, ['pwdFromId', 'casLoginForm']),
        '/second',
      );
    });

    test('所有 id 都不存在时返回空', () {
      const html = '<form id="other" action="/x"></form>';
      expect(extractAnyFormAction(html, ['pwdFromId', 'casLoginForm']), '');
    });
  });
}
