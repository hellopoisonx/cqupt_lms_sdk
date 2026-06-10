/// CQUPT LMS 客户端。
///
/// 提供：
/// - IDS 登录（带 session cookie 保存与恢复）；
/// - 活跃签到列表拉取（自动重登）；
/// - 三类签到提交（qr / number / radar）；
/// - 学生签到详情。
///
/// 全部接口均以 `Future` 形式返回，天然非阻塞。
///
/// 内部实现说明：
/// - 不使用第三方 cookie jar：自己维护一个「按域分组的」cookie 字典；
/// - 每次请求时把目标域 + 其父域的 cookie 拼到 `Cookie` 头；
/// - 每次响应解析 `set-cookie` 合并进字典（同域同 name 后到达覆盖）。
/// 这种实现与 rollcall-go 的 `cookiejar` 行为完全一致，但跨 Dart 平台可用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../cas/encryption.dart';
import '../cas/http_core.dart';
import '../exceptions.dart';
import '../http/no_redirect_client.dart';
import 'models.dart';


/// LMS 客户端配置。
class LmsConfig {
  const LmsConfig({
    this.lmsBase = 'http://lms.tc.cqupt.edu.cn',
    this.idsBase = 'https://ids.cqupt.edu.cn',
    this.apiVersion = '1.1.0',
    this.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36',
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 1),
  });

  final String lmsBase;
  final String idsBase;
  final String apiVersion;
  final String userAgent;
  final Duration timeout;

  /// 网络错误时最大重试次数（0 表示不重试）。
  ///
  /// 仅对连接中断、超时等网络层错误重试，不重试 HTTP 4xx/5xx 业务错误。
  final int maxRetries;

  /// 首次重试前的等待时间，后续按 2 倍递增（指数退避）。
  final Duration retryDelay;
}

/// LMS 客户端。线程安全（内部串行化请求）。
class LmsClient {
  LmsClient({LmsConfig? config, http.Client? client, Logger? logger})
      : this._internal(
          config: config ?? const LmsConfig(),
          rawClient: client ?? http.Client(),
          logger: logger,
        );

  LmsClient._internal({
    required LmsConfig config,
    required http.Client rawClient,
    Logger? logger,
  })  : _config = config,
        // 保存原始 client 以便 IdsHttpCore 复用同一连接池。
        _rawClient = rawClient,
        // 包装为 NoRedirectClient：登录协议依赖手动处理 302 重定向链。
        _http = NoRedirectClient(rawClient),
        _log = logger ?? Logger('cqupt_lms_sdk.lms');

  final LmsConfig _config;

  /// 原始 HTTP 客户端（供 IdsHttpCore 复用，避免关闭冲突）。
  final http.Client _rawClient;
  final NoRedirectClient _http;
  final Logger _log;

  /// 维护一个串行化的请求队列，避免竞态修改 cookie。
  final _queue = _SerialQueue();

  /// `domain -> { name -> cookie }`。同域同 name 后到达覆盖。
  final Map<String, Map<String, Cookie>> _jar = <String, Map<String, Cookie>>{};

  /// 客户端 ID，对应 rollcall-go 的 `config.ClientID`。
  /// 用户可显式覆盖；缺省时随机生成。
  String clientId = _generateClientId();

  /// 用户名/密码。可在 [login] 前设置，或在构造时由外部状态注入。
  String? username;
  String? password;
  /// 当前为 true 时，_login 内部即便完成也不再触发 [onSessionEstablished]。
  /// 用于在 getRollcalls 触发的自动重登中抑制回调。
  bool _suppressSessionCallback = false;

  /// 业务回调：登录成功后调用，可将 cookie / sessionId 持久化。
  void Function(LmsSession session)? onSessionEstablished;

  /// 业务回调：获取已保存的 session，用于无密码恢复。
  Future<LmsSession?> Function()? sessionLoader;

  /// 验证码回调：IDS 要求图形验证码时调用，返回用户输入的验证码字符串。
  /// 未设置时若遇到验证码则抛出 [CaptchaRequiredException]。
  Future<String> Function(Uint8List captchaImage)? onCaptchaRequired;

  /// 释放底层 [http.Client]。
  void close() => _http.close();

  // ------------------------------------------------------------------
  // 公开 API
  // ------------------------------------------------------------------

  /// 完整执行 IDS 登录。返回登录是否成功（session cookie 已写入 jar）。
  ///
  /// 每次 login 都会清空内部 cookie jar，确保与 Go `cookiejar.New(nil)` 行为一致。

  Future<bool> login({String? username, String? password}) async {
    if (username != null) this.username = username;
    if (password != null) this.password = password;
    if (this.username == null || this.password == null) {
      throw const LoginFailedException('LmsClient 缺少 username/password');
    }
    return _queue.run(() {
      _jar.clear();
      // _login 内部可能会被 getRollcalls 等接口的自动重登复用，
      // 通过 _notifySession 标记控制回调是否触发。
      _suppressSessionCallback = false;
      return _login(this.username!, this.password!);
    });
  }

  /// 获取当前所有活跃签到。会话过期时会自动重登一次。
  Future<List<Rollcall>> getRollcalls({bool autoRelogin = true}) async {
    return _queue.run(() => _getRollcalls(autoRelogin));
  }

  /// 获取某个签到的学生签到详情。会话过期时会自动重登一次。
  Future<StudentRollcallsData?> getStudentRollcalls(int rollcallId,
      {bool autoRelogin = true}) async {
    return _queue.run(() => _getStudentRollcalls(rollcallId, autoRelogin));
  }

  /// 提交签到。
  ///
  /// [type] 取值 `qr` / `number` / `radar`。
  /// [payload] 字段含义：
  ///   - `qr`: `{ "data": "<hex 42 位>" }`
  ///   - `number`: `{ "numberCode": "1234" }`
  ///   - `radar`: `{ "lat": 29.53, "lon": 106.60 }`
  Future<CheckinResult> doCheckin(
    int rollcallId,
    String type,
    Map<String, dynamic> payload,
  ) async {
    return _queue.run(() => _doCheckin(rollcallId, type, payload));
  }

  /// 手动注入已保存的 session，恢复登录态。
  void restoreSession(LmsSession session) {
    final domain = _hostOf(_config.lmsBase);
    final map = _jar.putIfAbsent(domain, () => <String, Cookie>{});
    for (final c in session.cookies) {
      map[c.name] = Cookie(name: c.name, value: c.value, domain: domain, path: c.path);
    }
  }

  // ------------------------------------------------------------------
  // 内部流程
  // ------------------------------------------------------------------

  Future<bool> _login(String username, String password) async {
    // Step 1: follow /login redirect chain to extract the CAS service URL.
    final (serviceUrl, redirected) = await _resolveServiceUrl();
    _log.fine('serviceUrl = $serviceUrl, redirected = $redirected');
    if (serviceUrl.isEmpty) {
      throw const LoginFailedException(
          '未拿到 service URL（redirect 链可能不通）');
    }

    // Step 2-5: delegate IDS authentication to IdsHttpCore.
    final core = IdsHttpCore.create(
      targetService: serviceUrl,
      config: IdsConfig(
        baseUrl: '${_config.idsBase}/authserver/login',
        userAgent: _config.userAgent,
        timeout: _config.timeout,
        maxRetries: _config.maxRetries,
        retryDelay: _config.retryDelay,
      ),
      client: _rawClient,
    );
    try {
      await core.fetchGlobalCookie();
      final page = await core.fetchLoginPage();
      if (page.execution.isEmpty) {
        throw const LoginFailedException('IDS 登录页解析失败：缺少 execution');
      }

      // Handle captcha if required.
      String captcha = '';
      if (await core.checkNeedCaptcha(username)) {
        if (onCaptchaRequired != null) {
          final img = await core.fetchCaptcha();
          captcha = (await onCaptchaRequired!(img)).trim();
          if (captcha.isEmpty) throw const CaptchaSolveException();
        } else {
          throw const CaptchaRequiredException();
        }
      }

      // Encrypt password and submit login form.
      final encPwd = encryptPassword(password, page.pwdEncryptSalt);
      final loc = await core.submitLogin(
        username: username,
        encryptedPassword: encPwd,
        captcha: captcha,
        execution: page.execution,
      );
      if (loc == null || loc.isEmpty) {
        throw const LoginFailedException('登录失败：未收到有效 Location 头');
      }

      // Follow CAS ticket redirect chain to get LMS session cookie.
      await _followAllRedirects(loc);
    } finally {
      // IdsHttpCore wraps _rawClient in its own NoRedirectClient；closing
      // core would close _rawClient prematurely. Use dispose() to clean up
      // internal state without closing the shared underlying client.
      core.dispose();
    }

    // Verify session cookie on LMS domain.
    if (_hasSessionCookie()) {
      if (!_suppressSessionCallback) {
        onSessionEstablished?.call(LmsSession(
          clientId: clientId,
          username: username,
          cookies: _exportCookies(_config.lmsBase),
          savedAt: DateTime.now(),
        ));
      } else {
        _log.fine('自动重登完成（已抑制 onSessionEstablished 回调）');
      }
      _log.info('IDS 登录成功: $username');
      return true;
    }
    throw LoginFailedException(
        '登录失败：未找到 session cookie（已跟 Location 但无 session）。'
        '可能原因：账号/密码错误、被踢出会话、IDS 风控要求验证码。'
        '可重试并开启 logger.level = Level.ALL 查看详细状态码。');
  }


  Future<List<Rollcall>> _getRollcalls(bool canRetry) async {
    final url = '${_config.lmsBase}/api/radar/rollcalls'
        '?api_version=${_config.apiVersion}';
    final resp = await _request('GET', url);
    if (resp.statusCode == 302 || resp.statusCode == 401) {
      if (canRetry && await _tryRelogin()) {
        return _getRollcalls(false);
      }
      return const <Rollcall>[];
    }
    if (resp.statusCode != 200) {
      throw HttpStatusException(resp.statusCode, resp.body);
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw HttpStatusException(resp.statusCode, 'invalid json');
    }
    final list = (decoded['rollcalls'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(Rollcall.fromJson)
        .toList(growable: false);
    return list;
  }

  Future<StudentRollcallsData?> _getStudentRollcalls(
      int rollcallId, bool canRetry) async {
    final url = '${_config.lmsBase}/api/rollcall/$rollcallId/student_rollcalls';
    final resp = await _request('GET', url);
    if (resp.statusCode == 302 || resp.statusCode == 401) {
      if (canRetry && await _tryRelogin()) {
        return _getStudentRollcalls(rollcallId, false);
      }
      return null;
    }
    if (resp.statusCode != 200) {
      throw HttpStatusException(resp.statusCode, resp.body);
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map<String, dynamic>) return null;
    return StudentRollcallsData.fromJson(decoded);
  }

  Future<CheckinResult> _doCheckin(
    int rollcallId,
    String type,
    Map<String, dynamic> payload,
  ) async {
    final endpoint = switch (type) {
      'qr' => '${_config.lmsBase}/api/rollcall/$rollcallId/answer_qr_rollcall',
      'number' =>
        '${_config.lmsBase}/api/rollcall/$rollcallId/answer_number_rollcall',
      'radar' => '${_config.lmsBase}/api/rollcall/$rollcallId/answer',
      _ => null,
    };
    if (endpoint == null) {
      return const CheckinResult(success: false, errorCode: 'unknown type');
    }
    final body = <String, dynamic>{...payload, 'deviceId': clientId};
    final resp = await _request('PUT', endpoint, jsonBody: body);
    Map<String, dynamic> decoded = const <String, dynamic>{};
    if (resp.bodyBytes.isNotEmpty) {
      try {
        final raw = jsonDecode(utf8.decode(resp.bodyBytes));
        if (raw is Map<String, dynamic>) decoded = raw;
      } on FormatException {
        // 忽略非 JSON 响应。
      }
    }
    final status = decoded['status'] as String? ?? '';
    if (resp.statusCode == 200 && status == 'on_call') {
      return const CheckinResult(success: true);
    }
    final errCode = (decoded['error_code'] as String?) ??
        (decoded['message'] as String? ?? '');
    _log.warning('签到失败: id=$rollcallId, type=$type, code=$errCode');
    return CheckinResult(success: false, errorCode: errCode);
  }

  Future<bool> _tryRelogin() async {
    if (username == null || password == null) {
      final session = await sessionLoader?.call();
      if (session == null) return false;
      username = session.username;
      restoreSession(session);
      return _hasSessionCookie();
    }
    try {
      _suppressSessionCallback = true;
      final ok = await _login(username!, password!);
      _suppressSessionCallback = false;
      return ok;
    } on Object catch (e, st) {
      _log.warning('重登失败: $e', e, st);
      return false;
    }
  }

  // ------------------------------------------------------------------
  // HTTP / cookie
  // ------------------------------------------------------------------

  /// 跟随 /login 重定向链，提取 CAS service URL。
  /// 返回 `(serviceUrl, didRedirect)`。
  Future<(String, bool)> _resolveServiceUrl() async {
    var current = '${_config.lmsBase}/login';
    var redirected = false;
    for (var i = 0; i < 20; i++) {
      final resp = await _request('GET', current);
      if (!_isRedirect(resp.statusCode)) break;
      final loc = resp.headers['location'];
      if (loc == null || loc.isEmpty) break;
      current = _resolveUrl(current, loc);
      redirected = true;
    }
    // 从最终 URL 的 query 中提取 service 参数值（原始 service URL）。
    try {
      final uri = Uri.parse(current);
      final svc = uri.queryParameters['service'];
      if (svc != null && svc.isNotEmpty) {
        return (Uri.decodeQueryComponent(svc), redirected);
      }
    } on FormatException { /* fall through */ }
    return (redirected ? '${_config.lmsBase}/login' : '', redirected);
  }

  Future<void> _followAllRedirects(String startUrl) async {
    var current = startUrl;
    for (var i = 0; i < 20; i++) {
      final resp = await _request('GET', current);
      if (!_isRedirect(resp.statusCode)) return;
      final loc = resp.headers['location'];
      if (loc == null || loc.isEmpty) return;
      current = _resolveUrl(current, loc);
    }
  }

  /// 发送 HTTP 请求并自动重试网络层错误。
  ///
  /// 重试策略（指数退避）：仅重试连接中断和超时，不重试 4xx/5xx。
  Future<http.Response> _request(
    String method,
    String url, {
    Map<String, String>? formData,
    Map<String, dynamic>? jsonBody,
  }) async {
    final uri = Uri.parse(url);
    final headers = <String, String>{
      'User-Agent': _config.userAgent,
      'Cookie': _cookieHeaderFor(uri),
    };
    String? body;
    if (formData != null) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
      body = formData.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
    } else if (jsonBody != null) {
      headers['Content-Type'] = 'application/json';
      body = jsonEncode(jsonBody);
    }

    Future<http.Response> send() async {
      switch (method) {
        case 'GET':
          return _http.get(uri, headers: headers).timeout(_config.timeout);
        case 'POST':
          return _http
              .post(uri, headers: headers, body: body)
              .timeout(_config.timeout);
        case 'PUT':
          return _http
              .put(uri, headers: headers, body: body)
              .timeout(_config.timeout);
        case 'DELETE':
          return _http
              .delete(uri, headers: headers, body: body)
              .timeout(_config.timeout);
        default:
          throw HttpFailureException('不支持的 HTTP 方法: $method');
      }
    }

    Object? lastError;
    for (var attempt = 0; attempt <= _config.maxRetries; attempt++) {
      try {
        final resp = await send();
        _mergeCookiesFromResponse(uri, resp);
        return resp;
      } on TimeoutException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      }
      if (attempt < _config.maxRetries) {
        final delay = _config.retryDelay * (1 << attempt);
        await Future<void>.delayed(delay);
      }
    }

    final retryNote = _config.maxRetries > 0 ? '（已重试 ${_config.maxRetries} 次）' : '';
    if (lastError is TimeoutException) {
      throw HttpFailureException('请求超时$retryNote: $method $url', lastError);
    }
    if (lastError is http.ClientException) {
      throw HttpFailureException(
          'HTTP 客户端错误$retryNote: ${lastError.message}',
          lastError);
    }
    throw HttpFailureException('请求失败$retryNote: $method $url', lastError);
  }

  // ---- cookie 维护 ----

  String _cookieHeaderFor(Uri uri) {
    final out = <String>[];
    for (final entry in _jar.entries) {
      final domain = entry.key;
      if (!_domainMatches(domain, uri.host)) continue;
      for (final c in entry.value.values) {
        if (!_pathMatches(c.path, uri.path)) continue;
        out.add('${c.name}=${c.value}');
      }
    }
    return out.join('; ');
  }

  void _mergeCookiesFromResponse(Uri requestUri, http.Response resp) {
    // http 1.6.0 的 BaseResponse 提供了 headersSplitValues 扩展，
    // 它已经按 RFC 6265 切分了多个 Set-Cookie。
    final cookies = resp.headersSplitValues['set-cookie'] ?? const <String>[];
    for (final cookieStr in cookies) {
      _parseAndStore(requestUri, cookieStr);
    }
  }

  /// 解析单条 Set-Cookie 字符串并存入 jar。
  void _parseAndStore(Uri requestUri, String cookieStr) {
    final parts = cookieStr.split(';').map((s) => s.trim()).toList();
    if (parts.isEmpty) return;
    final firstEq = parts[0].indexOf('=');
    if (firstEq <= 0) return;
    final name = parts[0].substring(0, firstEq);
    final value = parts[0].substring(firstEq + 1);

    String? domain;
    String? path;
    for (var i = 1; i < parts.length; i++) {
      final p = parts[i];
      final eq = p.indexOf('=');
      final k = (eq > 0 ? p.substring(0, eq) : p).toLowerCase();
      final v = eq > 0 ? p.substring(eq + 1) : '';
      if (k == 'domain') {
        domain = v.toLowerCase();
        if (domain.startsWith('.')) domain = domain.substring(1);
      } else if (k == 'path') {
        path = v;
      }
    }
    domain ??= requestUri.host;
    path ??= '/';
    final bucket = _jar.putIfAbsent(domain, () => <String, Cookie>{});
    bucket[name] = Cookie(name: name, value: value, domain: domain, path: path);
  }

  bool _domainMatches(String domain, String host) {
    if (domain.isEmpty) return false;
    final h = host.toLowerCase();
    if (h == domain) return true;
    return h.endsWith('.$domain');
  }

  bool _pathMatches(String cookiePath, String requestPath) {
    if (cookiePath.isEmpty) cookiePath = '/';
    if (requestPath.startsWith(cookiePath)) return true;
    return requestPath == cookiePath;
  }

  bool _hasSessionCookie() {
    final domain = _hostOf(_config.lmsBase);
    final bucket = _jar[domain];
    if (bucket == null) return false;
    return bucket.containsKey('session');
  }

  List<Cookie> _exportCookies(String baseUrl) {
    final domain = _hostOf(baseUrl);
    return List.unmodifiable(_jar[domain]?.values ?? const <Cookie>[]);
  }

  // ------------------------------------------------------------------

  bool _isRedirect(int code) =>
      code == 301 || code == 302 || code == 303 || code == 307 || code == 308;

  String _resolveUrl(String base, String ref) {
    try {
      return Uri.parse(base).resolveUri(Uri.parse(ref)).toString();
    } on FormatException {
      return ref;
    }
  }

  String _hostOf(String baseUrl) {
    try {
      return Uri.parse(baseUrl).host.toLowerCase();
    } on FormatException {
      return '';
    }
  }

  }

class Cookie {
  const Cookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
  });
  final String name;
  final String value;
  final String domain;
  final String path;
}

/// 业务层用于持久化的最小登录态。
class LmsSession {
  const LmsSession({
    required this.clientId,
    required this.username,
    required this.cookies,
    required this.savedAt,
  });

  final String clientId;
  final String username;
  final List<Cookie> cookies;
  final DateTime savedAt;
  Map<String, dynamic> toJson() => {
        'client_id': clientId,
        'username': username,
        'cookies': cookies
            .map((c) => {
                  'name': c.name,
                  'value': c.value,
                  'domain': c.domain,
                  'path': c.path,
                })
            .toList(),
        'saved_at': savedAt.toIso8601String(),
      };

  static LmsSession fromJson(Map<String, dynamic> json) {
    final list = (json['cookies'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map((c) => Cookie(
              name: c['name'] as String,
              value: c['value'] as String,
              domain: c['domain'] as String? ?? '',
              path: c['path'] as String? ?? '/',
            ))
        .toList();
    return LmsSession(
      clientId: json['client_id'] as String? ?? '',
      username: json['username'] as String? ?? '',
      cookies: list,
      savedAt:
          DateTime.tryParse(json['saved_at'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

String _generateClientId() {
  // 用时间戳 + 微秒部分拼一个看起来唯一的字符串。
  final now = DateTime.now();
  return 'dart-${now.microsecondsSinceEpoch.toRadixString(36)}-'
      '${(now.millisecond ^ now.microsecond).toRadixString(36)}';
}

/// 内部串行化队列。
class _SerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    final next = _tail.then((_) async {
      try {
        completer.complete(await task());
      } on Object catch (e, st) {
        completer.completeError(e, st);
      }
    });
    _tail = next.catchError((_) {});
    return completer.future;
  }
}
