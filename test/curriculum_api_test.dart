import 'dart:async';
import 'dart:convert';

import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  group('CurriculumApi', () {
    test('把 studentId 拼进 {studentId} 占位符', () async {
      final client = _ScriptedClient([
        _Stub((req) async {
          // 校验实际请求的 URL
          expect(req.url.toString(),
              'https://cqupt.ishub.top/api/curriculum/2024001234/curriculum.json');
          return http.Response(
            '{"instances":[]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ]);
      final api = CurriculumApi(
        studentId: '2024001234',
        client: client,
      );
      expect(api.requestUrl,
          'https://cqupt.ishub.top/api/curriculum/2024001234/curriculum.json');
      final data = await api.fetch();
      expect(data.instances, isEmpty);
      api.close();
    });

    test('对含特殊字符的 studentId 进行 url-encode', () async {
      final client = _ScriptedClient([
        _Stub((req) async {
          // 校验转义
          expect(req.url.path, '/api/curriculum/l%2F001/curriculum.json');
          return http.Response('{"instances":[]}', 200);
        }),
      ]);
      final api = CurriculumApi(
        studentId: 'l/001',
        client: client,
      );
      await api.fetch();
      api.close();
    });

    test('自定义 endpointTemplate', () async {
      final client = _ScriptedClient([
        _Stub((req) async {
          expect(req.url.toString(),
              'https://my.example.com/v2/cur/2024001.json');
          return http.Response('{"instances":[]}', 200);
        }),
      ]);
      final api = CurriculumApi(
        studentId: '2024001',
        config: const CurriculumApiConfig(
          endpointTemplate: 'https://my.example.com/v2/cur/{studentId}.json',
        ),
        client: client,
      );
      expect(api.requestUrl,
          'https://my.example.com/v2/cur/2024001.json');
      await api.fetch();
      api.close();
    });

    test('服务端 404 时抛出 HttpStatusException 并保留 body', () async {
      final client = _ScriptedClient([
        _Stub((req) async => http.Response('{"detail":"Not Found"}', 404)),
      ]);
      final api = CurriculumApi(studentId: '1696651', client: client);
      expect(
        () => api.fetch(),
        throwsA(
          isA<HttpStatusException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.body, 'body', contains('Not Found')),
        ),
      );
      api.close();
    });

    test('解析 instances 数组（含中文）', () async {
      final client = _ScriptedClient([
        _Stub((req) async => http.Response(
              jsonEncode({
                'instances': [
                  {
                    'date': '2026-06-10',
                    'start_time': '08:00',
                    'end_time': '09:40',
                    'course': '高等数学A',
                    'location': '2306',
                  },
                  {
                    'date': '2026-06-10',
                    'start_time': '10:00',
                    'end_time': '11:40',
                    'course': '大学英语',
                    'location': '4205',
                  },
                ],
              }),
              200,

              headers: {'content-type': 'application/json; charset=utf-8'},
            )),
      ]);
      final api = CurriculumApi(studentId: '2024001', client: client);
      final data = await api.fetch();
      expect(data.instances.length, 2);
      expect(data.instances[0].course, '高等数学A');
      expect(data.instances[0].location, '2306');
      expect(data.courses.toList(), ['高等数学A', '大学英语']);
      api.close();
    });

    test('客户端异常包装为 HttpFailureException', () async {
      final client = _ScriptedClient([
        _Stub((req) async => throw http.ClientException('boom')),
      ]);
      final api = CurriculumApi(studentId: '2024001', client: client);
      expect(
        () => api.fetch(),
        throwsA(
          isA<HttpFailureException>().having(
            (e) => e.message,
            'message',
            contains('课表 HTTP 客户端错误'),
          ),
        ),
      );
      api.close();
    });
  });
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
