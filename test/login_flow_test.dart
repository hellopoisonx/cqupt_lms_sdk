// 回归测试：覆盖登录链路里发现的几个 bug 修复点。
//
// 1. IdsHttpCore._loginPostUrl 必须返回 `baseUrl?service=…`，
//    不再出现 `?=service=` 笔误（曾导致 IDS 回
//    `exception.message=A problem occurred restoring the flow execution`）。
// 2. IdsHttpCore.fetchLoginPage 不再解析 `<form action>`，
//    IdsLoginPage.formAction 字段保留为空字符串以兼容历史 API。
// 3. LmsClient._resolveServiceUrl 跟 2 跳重定向并返回最终 URL 字符串，
//    与 rollcall-go 的 getCallbackURL 行为一致。

import 'dart:async';
import 'dart:convert';

import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  group('IdsHttpCore._loginPostUrl 修复回归', () {
    test('POST URL 永远是 baseUrl?service=<encoded target>，不再出现 ?= 笔误',
        () async {
      String? postedUrl;
      // IdsHttpCore 调用顺序：fetchGlobalCookie → fetchLoginPage → submitLogin
      // （captcha 探测不在 IdsHttpCore 路径里，由 CasSdk/LmsClient 决定是否调用）。
      final client = _ScriptedClient([
        // fetchGlobalCookie: GET idsLogin?service=… → 200
        _Stub((req) async => http.Response('', 200)),
        // fetchLoginPage: GET idsLogin?service=… → 200 + 表单
        _Stub((req) async => http.Response(
              _idsHtml(),
              200,
              headers: {'content-type': 'text/html'},
            )),
        // submitLogin: POST idsLogin?service=… → 302 + Location
        _Stub((req) async {
          postedUrl = req.url.toString();
          return http.Response('', 302, headers: {
            'location': 'http://lms.tc.cqupt.edu.cn/login?ticket=ST-abc',
          });
        }),
      ]);

      final core = IdsHttpCore.create(
        targetService: 'http://lms.tc.cqupt.edu.cn/login',
        client: client,
      );
      try {
        await core.fetchGlobalCookie();
        final page = await core.fetchLoginPage();
        // formAction 字段保留为空字符串，不再解析 form。
        expect(page.formAction, isEmpty,
            reason: 'fetchLoginPage 不再解析 <form action>');
        expect(page.execution, isNotEmpty);
        // 跳过 captcha 探测，直接 POST。
        await core.submitLogin(
          username: '2024001',
          encryptedPassword: 'aGVsbG8=',
          captcha: '',
          execution: page.execution,
        );
        expect(postedUrl, isNotNull);
        // 关键：URL 中绝对不能出现 ?= 这种残废 query 分隔符。
        expect(postedUrl!, isNot(contains('?=')),
            reason: 'POST URL 不应为「?=service=...」历史笔误');
        // 关键：URL 必须以 ?service= 开头（service 参数名正确）。
        expect(postedUrl, contains('?service='),
            reason: 'POST URL 必须以 ?service=<encoded> 形式');
      } finally {
        core.dispose();
      }
    });
  });

  group('LmsClient._resolveServiceUrl 与 rollcall-go 对齐', () {
    test('跟 2 跳重定向后返回最终 URL 字符串，不解析 query 中的 service',
        () async {
      // 真实链路：/login → Keycloak CAS protocol → Keycloak broker
      final step2 =
          'http://identity.tc.cqupt.edu.cn/auth/realms/cqupt/protocol/cas/login'
          '?service=http%3A//lms.tc.cqupt.edu.cn/login';
      final step3 =
          'http://identity.tc.cqupt.edu.cn/auth/realms/cqupt/broker/cas-client/login'
          '?session_code=ABC&client_id=tronclass';

      // stub[0..1] 控制 _resolveServiceUrl 的 2 跳重定向链，
      // stub[2..] 复用 happy path 收尾。
      final stubs = <_Stub>[
        // stub[0]: _resolveServiceUrl 第 0 跳：/login → 302 → step2
        _Stub((req) async => http.Response('', 302, headers: {
              'location': step2,
            })),
        // stub[1]: _resolveServiceUrl 第 1 跳：step2 → 303 → step3（循环退出）
        _Stub((req) async => http.Response('', 303, headers: {
              'location': step3,
            })),
        ..._captchaOffHappyPathStubs(),
      ];
      final client = _ScriptedClient(stubs);
      final lms = LmsClient(client: client);
      addTearDown(lms.close);

      await lms.login(username: '2024001', password: 'secret');

      // 关键断言：发起过的 URL 序列里 step3 不应再出现。
      // rollcall-go 只跟 2 跳；LmsClient 现在也只跟 2 跳。
      final urls = client.calls.map((c) => c.url.toString()).toList();
      expect(urls.first, 'http://lms.tc.cqupt.edu.cn/login');
      expect(urls.contains(step2), isTrue,
          reason: '应跟到 step2 这一次');
      expect(urls.contains(step3), isFalse,
          reason: 'rollcall-go 只跟 2 跳，不应继续跟 step3');

      // 关键断言：fetchGlobalCookie 拿到的 service URL 必须是 step3 整体
      // （不是剥掉 query 后的「lms/login」兜底）。
      final fetchGlobalCookie = urls.firstWhere(
          (u) => u.contains('/authserver/login?service='),
          orElse: () => '');
      expect(fetchGlobalCookie, isNotEmpty,
          reason: '应看到 fetchGlobalCookie 的 GET');
      // service 应包含完整 step3 的 broker 路径，而非兜底 lms/login。
      expect(fetchGlobalCookie, contains('identity.tc.cqupt.edu.cn'));
      expect(fetchGlobalCookie, contains('broker'),
          reason: 'service 应包含完整 step3 的 broker 路径');
      expect(fetchGlobalCookie, isNot(contains('lms.tc.cqupt.edu.cn%2Flogin%26')),
          reason: '不应是旧版剥 query 后的兜底 service');
    });
  });
}

/// 登录 happy path 后续 stub（假定 `_resolveServiceUrl` 已经返回 final URL）。
///
/// 顺序：
///   stub[0]: GET idsLogin?service=… → 200（fetchGlobalCookie）
///   stub[1]: GET idsLogin?service=… → 200 + 表单（fetchLoginPage）
///   stub[2]: GET checkNeedCaptcha.htl → 200 + {"isNeed":false}
///   stub[3]: POST idsLogin?service=… → 302 + Location（submitLogin）
///   stub[4]: GET Location → 200 + session cookie（_followAllRedirects）
List<_Stub> _captchaOffHappyPathStubs() {
  return [
    _Stub((req) async => http.Response('', 200)),
    _Stub((req) async => http.Response(
          _idsHtml(),
          200,
          headers: {'content-type': 'text/html'},
        )),
    _Stub((req) async => http.Response(
          '{"isNeed":false}',
          200,
          headers: {'content-type': 'application/json'},
        )),
    _Stub((req) async => http.Response('', 302, headers: {
          'location': 'http://lms.tc.cqupt.edu.cn/tysfrz/navication.php?id=user',
        })),
    _Stub((req) async => http.Response('ok', 200, headers: {
          'set-cookie':
              'session=session_value_123; Domain=lms.tc.cqupt.edu.cn; Path=/',
        })),
  ];
}

String _idsHtml() => '''
<html><body>
  <input id="pwdEncryptSalt" value="saltsaltsaltsalt" />
  <input id="execution" name="execution" value="exec-abc" />
  <form id="pwdFromId" action="/authserver/login"></form>
</body></html>
''';

class _Stub {
  _Stub(this.handler);
  final Future<http.Response> Function(http.BaseRequest req) handler;
}

class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.stubs);
  final List<_Stub> stubs;
  final List<_RecordedCall> calls = <_RecordedCall>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.followRedirects = false;
    calls.add(_RecordedCall(
      request.method,
      request.url,
      request.followRedirects,
    ));
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

class _RecordedCall {
  _RecordedCall(this.method, this.url, this.followRedirects);
  final String method;
  final Uri url;
  final bool followRedirects;
}
