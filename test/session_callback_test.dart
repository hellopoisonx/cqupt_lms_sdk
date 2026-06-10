import 'dart:async';
import 'dart:convert';

import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  group('LmsClient.onSessionEstablished 抑制规则', () {
    test('用户主动 login 触发一次', () async {
      final client = _ScriptedClient(_happyLoginStubs());
      final lms = LmsClient(client: client);
      var count = 0;
      lms.onSessionEstablished = (_) => count++;
      await lms.login(username: '2024001', password: 'secret');
      expect(count, 1);
      lms.close();
    });

    test('getRollcalls 触发自动重登时不再调用回调', () async {
      final client = _ScriptedClient([
        // 1. login happy path
        ..._happyLoginStubs(),
        // 2. getRollcalls 第一次：401，触发 _tryRelogin
        _Stub((req) async => http.Response('unauth', 401)),
        // 3. _tryRelogin 复用的 login happy path
        ..._happyLoginStubs(),
        // 4. 第二次 getRollcalls：200 + 空
        _Stub((req) async => http.Response(
              '{"rollcalls":[]}',
              200,
              headers: {'content-type': 'application/json'},
            )),
      ]);
      final lms = LmsClient(client: client);
      var count = 0;
      lms.onSessionEstablished = (_) => count++;
      await lms.login(username: '2024001', password: 'secret');
      expect(count, 1, reason: 'login 阶段触发 1 次');
      await lms.getRollcalls();
      expect(count, 1, reason: '重登不应再次触发 callback');
      lms.close();
    });
  });
}

/// 完整登录 happy path 所需的所有请求 stub。
///
/// 实际请求顺序（LmsClient 复用 IdsHttpCore 后）：
///   1. GET lms/login → 302 + Location（_resolveServiceUrl 初跳）
///   2. GET Location → 200（_resolveServiceUrl 跳转结束，提取 service URL）
///   3. GET idsLogin?service=... → 200（fetchGlobalCookie）
///   4. GET idsLogin?service=... → 200 + 表单（fetchLoginPage）
///   5. GET checkNeedCaptcha.htl → 200 + {"isNeed":false}
///   6. POST login → 302 + Location + Set-Cookie
///   7. GET Location（_followAllRedirects）→ 200 + Set-Cookie session
List<_Stub> _happyLoginStubs() {
  final idsLogin = Uri.parse(
      'https://ids.cqupt.edu.cn/authserver/login?service=callback');
  String idsHtml() => '''
<html><body>
  <input id="pwdEncryptSalt" value="saltsaltsaltsalt" />
  <input id="execution" name="execution" value="exec-abc" />
  <form id="pwdFromId" action="/authserver/login"></form>
</body></html>
''';
  return [
    // 1. _resolveServiceUrl: GET lms/login → 302 → IDS
    _Stub((req) async => http.Response('', 302, headers: {
          'location': idsLogin.toString(),
        })),
    // 2. _resolveServiceUrl: GET IDS login page → 200（循环终止，提取 service=callback）
    _Stub((req) async => http.Response(
          idsHtml(),
          200,
          headers: {'content-type': 'text/html'},
        )),
    // 3. fetchGlobalCookie: GET idsLogin?service=callback → 200
    _Stub((req) async => http.Response('', 200)),
    // 4. fetchLoginPage: GET idsLogin?service=callback → 200 + 表单
    _Stub((req) async => http.Response(
          idsHtml(),
          200,
          headers: {'content-type': 'text/html'},
        )),
    // 5. checkNeedCaptcha: GET checkNeedCaptcha.htl → 200 + {"isNeed":false}
    _Stub((req) async => http.Response(
          '{"isNeed":false}',
          200,
          headers: {'content-type': 'application/json'},
        )),
    // 6. submitLogin: POST login → 302 + Location + Set-Cookie
    _Stub((req) async {
      if (req.method == 'POST') {
        return http.Response('', 302, headers: {
          'location': 'http://lms.tc.cqupt.edu.cn/tysfrz/navication.php?id=user',
          'set-cookie': 'session=session_value_123; Path=/',
        });
      }
      return http.Response('unexpected method: ${req.method}', 500);
    }),
    // 7. _followAllRedirects: GET Location → 200 + Set-Cookie session
    _Stub((req) async => http.Response('ok', 200, headers: {
          'set-cookie':
              'session=session_value_123; Domain=lms.tc.cqupt.edu.cn; Path=/',
        })),
  ];
}

class _Stub {
  _Stub(this.handler);
  final Future<http.Response> Function(http.BaseRequest req) handler;
}

class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.stubs);
  final List<_Stub> stubs;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.followRedirects = false;
    if (stubs.isEmpty) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('')),
        500,
        reasonPhrase: 'no stub: ${request.method} ${request.url}',
        request: request,
      );
    }
    final stub = stubs.removeAt(0);
    final resp = await stub.handler(request);
    return http.StreamedResponse(
      Stream.value(resp.bodyBytes),
      resp.statusCode,
      contentLength: resp.contentLength,
      reasonPhrase: resp.reasonPhrase,
      headers: resp.headers,
      request: request,
      isRedirect: resp.isRedirect,
      persistentConnection: resp.persistentConnection,
    );
  }
}
