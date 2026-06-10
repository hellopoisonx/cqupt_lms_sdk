import 'dart:async';
import 'dart:convert';

import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  group('NoRedirectClient', () {
    test('禁用自动重定向：返回 302 + Location 而非跟到底', () async {
      final client = _ScriptedClient([
        // 第一次 GET：302 + Location
        _Stub((req) async => http.Response('', 302, headers: {
              'location': 'https://other.example.com/final',
            })),
      ]);
      final wrapped = NoRedirectClient(client);
      final resp = await wrapped.get(Uri.parse('https://a.example.com/start'));
      expect(resp.statusCode, 302);
      expect(resp.headers['location'], 'https://other.example.com/final');
      expect(client.calls.length, 1); // 不会被自动跟到底
    });

    test('传 GET/POST 都关闭 followRedirects', () async {
      final client = _ScriptedClient([
        _Stub((req) async => http.Response('ok', 200)),
      ]);
      final wrapped = NoRedirectClient(client);
      await wrapped.get(Uri.parse('https://x.example.com/a'));
      await wrapped.post(Uri.parse('https://x.example.com/b'), body: '');
      for (final c in client.calls) {
        expect(c.followRedirects, isFalse,
            reason: '${c.method} ${c.url} 不应跟随重定向');
      }
    });
  });
}

class _RecordedCall {
  _RecordedCall(this.method, this.url, this.followRedirects);
  final String method;
  final Uri url;
  final bool followRedirects;
}

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
    calls.add(_RecordedCall(
      request.method,
      request.url,
      request.followRedirects,
    ));
    if (stubs.isEmpty) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('')),
        500,
        reasonPhrase: 'no stub',
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
