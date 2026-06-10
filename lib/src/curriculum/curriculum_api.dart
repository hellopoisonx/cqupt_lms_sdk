/// 课表 API 客户端。
///
/// rollcall-go 把 URL 拼成 `https://cqupt.ishub.top/api/curriculum/<学号>/curriculum.json`。
/// 本模块对调用方暴露「传入学号，拿到 CurriculumData」的最简形态。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../exceptions.dart';
import 'curriculum.dart';

/// 课表 API 配置。
class CurriculumApiConfig {
  const CurriculumApiConfig({
    this.endpointTemplate =
        'https://cqupt.ishub.top/api/curriculum/{studentId}/curriculum.json',
    this.timeout = const Duration(seconds: 15),
  });
  final String endpointTemplate;
  final Duration timeout;
}

/// 课表客户端。
class CurriculumApi {
  CurriculumApi({
    required String studentId,
    CurriculumApiConfig config = const CurriculumApiConfig(),
    http.Client? client,
  })  : _studentId = studentId,
        _config = config,
        _http = client ?? http.Client();

  final String _studentId;
  final CurriculumApiConfig _config;
  final http.Client _http;

  /// 实际请求的 URL。供调试时打印。
  String get requestUrl => _config.endpointTemplate.replaceAll(
        '{studentId}',
        Uri.encodeComponent(_studentId),
      );

  /// 拉取一次课表。
  Future<CurriculumData> fetch() async {
    final url = requestUrl;
    try {
      final resp = await _http.get(Uri.parse(url)).timeout(_config.timeout);
      if (resp.statusCode != 200) {
        throw HttpStatusException(resp.statusCode, resp.body);
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw HttpStatusException(resp.statusCode, 'invalid json');
      }
      return CurriculumData.fromJson(decoded);
    } on TimeoutException catch (e) {
      throw HttpFailureException('课表请求超时', e);
    } on http.ClientException catch (e) {
      throw HttpFailureException('课表 HTTP 客户端错误: ${e.message}', e);
    }
  }

  /// 释放底层 [http.Client]。
  void close() => _http.close();
}
