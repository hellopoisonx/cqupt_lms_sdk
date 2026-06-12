/// IDS 登录使用的 HTTP 核心。
///
/// 负责：
/// - 维护一个有序的 cookie 存储（同名后到达覆盖）；
/// - 模拟 Go `HttpSpyderCore` 的 `checkNeedCaptcha` / `getCaptcha` 流程；
/// - 解析登录页提取 salt、execution（不再解析 `<form action>`）；
/// - 提交表单并返回最终 `Location`（含「踢出会话」二次确认）。
///
/// POST URL 固定为 `baseUrl?service=<targetService>`，与 rollcall-go 一致；
/// 历史版本曾根据 form action 改写 POST URL，因字符串模板笔误而废弃。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../exceptions.dart';
import '../http/no_redirect_client.dart';
import 'extractor.dart';

/// IDS 登录所需的运行时配置。
class IdsConfig {
  const IdsConfig({
    this.baseUrl = 'https://ids.cqupt.edu.cn/authserver/login',
    // 与 rollcall-go 的 userAgent 字面值一致：服务端风控策略对 UA 敏感，
    // 偏离 Go 的历史 UA 可能触发验证码弹窗或拒绝签发 ticket。
    this.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36',
    this.timeout = const Duration(seconds: 15),
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 1),
  });

  final String baseUrl;
  final String userAgent;
  final Duration timeout;

  /// 网络错误时最大重试次数（0 表示不重试）。
  ///
  /// 仅对连接中断、超时等网络层错误重试，不重试 HTTP 4xx/5xx 业务错误。
  final int maxRetries;

  /// 首次重试前的等待时间，后续按 2 倍递增（指数退避）。
  final Duration retryDelay;

  /// 不带尾部 `/login` 的 base URL，用于拼接 `checkNeedCaptcha.htl` 等。
  String get idsOrigin => baseUrl.endsWith('/login')
      ? baseUrl.substring(0, baseUrl.length - '/login'.length)
      : baseUrl;
}

/// IDS 登录 HTTP 核心。
///
/// 每个登录流程对应一个新实例；登录结束后若需复用 cookie，可调用 [cookies] 取出。
class IdsHttpCore {
  IdsHttpCore._(this.config, this._targetService, this._http);

  /// 构造时使用的配置。
  final IdsConfig config;

  /// 经 url-encode 后的目标 service。
  final String _targetService;
  final NoRedirectClient _http;

  /// `name -> value`，按首次插入顺序保存，用于稳定地输出 `Cookie` 头。
  final Map<String, String> _cookieMap = <String, String>{};
  final List<String> _cookieOrder = <String>[];

  /// 当前累积的 `Cookie` 头。
  String get cookies {
    final out = <String>[];
    for (final name in _cookieOrder) {
      final v = _cookieMap[name];
      if (v != null) out.add('$name=$v');
    }
    return out.join('; ');
  }

  /// 加载已保存的 cookies。供跨进程复用登录态时使用。
  void loadCookies(String raw) {
    for (final part in raw.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final idx = trimmed.indexOf('=');
      if (idx <= 0) continue;
      _setCookie(trimmed.substring(0, idx), trimmed.substring(idx + 1));
    }
  }

  /// 创建并初始化核心。
  static IdsHttpCore create({
    required String targetService,
    IdsConfig config = const IdsConfig(),
    http.Client? client,
  }) {
    // 包装为 NoRedirectClient：登录协议需要手动处理 302。
    final c = NoRedirectClient(client ?? http.Client());
    return IdsHttpCore._(config, Uri.encodeQueryComponent(targetService), c);
  }

  /// 释放底层 `http.Client`。
  void close() => _http.close();

  /// 清理内部状态但不关闭底层 [http.Client]。
  ///
  /// 当 [IdsHttpCore] 通过 [create] 的 [client] 参数复用了外部 client 时，
  /// 调用方应使用此方法代替 [close]，避免过早关闭共享的底层连接。
  void dispose() {
    _cookieMap.clear();
    _cookieOrder.clear();
  }

  // ------------------------------------------------------------------
  // Cookie 合并
  // ------------------------------------------------------------------

  void _setCookie(String name, String value) {
    if (!_cookieMap.containsKey(name)) {
      _cookieOrder.add(name);
    }
    _cookieMap[name] = value;
  }

  void _mergeCookiesFromResponse(http.Response resp) {
    // http 包的 headers 已经是合并后的 Map<String, String>，但 Set-Cookie
    // 的值里会含逗号（如 Expires），所以走 [headersSplitValues] 扩展。
    final cookies = resp.headersSplitValues['set-cookie'] ?? const <String>[];
    for (final raw in cookies) {
      final semi = raw.indexOf(';');
      final head = (semi >= 0 ? raw.substring(0, semi) : raw).trim();
      if (head.isEmpty) continue;
      final eq = head.indexOf('=');
      if (eq <= 0) continue;
      _setCookie(head.substring(0, eq), head.substring(eq + 1));
    }
  }

  // ------------------------------------------------------------------
  // 基础请求
  // ------------------------------------------------------------------

  Map<String, String> _baseHeaders({String? contentType}) {
    final h = <String, String>{
      'User-Agent': config.userAgent,
      'Cookie': cookies,
    };
    if (contentType != null) h['Content-Type'] = contentType;
    // 不显式设置 Origin：与 rollcall-go 的请求序列一致，
    // 避免服务端 Origin 校验差异导致 401/400。
    return h;
  }

  Future<http.Response> _get(String url) => _send(
        () => _http.get(Uri.parse(url), headers: _baseHeaders()).timeout(config.timeout),
      );

  Future<http.Response> _post(String url, String body, {String? contentType}) {
    return _send(
      () => _http
          .post(
            Uri.parse(url),
            headers: _baseHeaders(
              contentType: contentType ?? 'application/x-www-form-urlencoded',
            ),
            body: body,
          )
          .timeout(config.timeout),
    );
  }

  /// 发送请求并自动重试网络层错误。
  ///
  /// 重试策略（指数退避）：
  /// - 第 0 次：立即发起；
  /// - 第 1 次：等待 [IdsConfig.retryDelay]；
  /// - 第 2 次：等待 2×[IdsConfig.retryDelay]；
  /// - …最多 [IdsConfig.maxRetries] 次重试。
  ///
  /// 仅重试：连接中断（[http.ClientException]）和超时（[TimeoutException]）。
  /// 不重试：HTTP 4xx/5xx 业务错误（那些已在调用方处理）。
  Future<http.Response> _send(Future<http.Response> Function() fn) async {
    Object? lastError;
    for (var attempt = 0; attempt <= config.maxRetries; attempt++) {
      try {
        final resp = await fn();
        _mergeCookiesFromResponse(resp);
        return resp;
      } on TimeoutException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      }
      if (attempt < config.maxRetries) {
        // 指数退避：retryDelay * 2^attempt
        final delay = config.retryDelay * (1 << attempt);
        await Future<void>.delayed(delay);
      }
    }

    // 所有重试均耗尽
    final retryNote = config.maxRetries > 0 ? '（已重试 ${config.maxRetries} 次）' : '';
    if (lastError is TimeoutException) {
      throw HttpFailureException('请求超时$retryNote', lastError);
    }
    if (lastError is http.ClientException) {
      throw HttpFailureException('HTTP 客户端错误$retryNote: ${lastError.message}', lastError);
    }
    throw HttpFailureException('请求失败$retryNote', lastError);
  }

  // ------------------------------------------------------------------
  // 登录流程分步
  // ------------------------------------------------------------------

  /// Step 1：访问 `?service=...` 以获取 JssID / router 等基础 cookie。
  Future<void> fetchGlobalCookie() async {
    final url = '${config.baseUrl}?service=$_targetService';
    await _get(url);
  }

  /// Step 2：访问登录页，提取 salt / execution。
  ///
  /// 不再解析 `<form action>`：早期实现把 form action 解析后拼成 POST URL，
  /// 但拼接时 `$sep=service=…` 模板笔误会让 URL 变成 `…/login?=service=…`，
  /// 服务端会回 `exception.message=A problem occurred restoring the flow
  /// execution with key '…'`，导致登录后拿不到合法 Location。
  /// 现在与 rollcall-go 对齐：永远 POST 到 `baseUrl?service=<targetService>`。
  /// [formAction] 字段保留为兼容历史 API，永远为空字符串。
  Future<IdsLoginPage> fetchLoginPage() async {
    final url = '${config.baseUrl}?service=$_targetService';
    final resp = await _get(url);
    if (resp.statusCode != 200) {
      throw HttpStatusException(resp.statusCode, resp.body);
    }
    final salt = extractInputValue(resp.body, ['id="pwdEncryptSalt"']);
    final execution = extractInputValue(resp.body, [
      'id="execution"',
      'name="execution"',
    ]);
    return IdsLoginPage(
      pwdEncryptSalt: salt,
      execution: execution,
      formAction: '',
    );
  }

  /// Step 3：查询是否需要图形验证码。
  ///
  /// 接口偶发异常时按「不需要验证码」降级，与 Go 行为一致。
  Future<bool> checkNeedCaptcha(String username) async {
    final url = '${config.idsOrigin}'
        '/checkNeedCaptcha.htl'
        '?username=${Uri.encodeQueryComponent(username)}'
        '&_=${DateTime.now().millisecondsSinceEpoch}';
    final http.Response resp;
    try {
      resp = await _get(url);
    } on Object {
      return false;
    }
    final raw = utf8.decode(resp.bodyBytes).trim();
    if (raw.isEmpty) return false;
    if (raw.startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['isNeed'] is bool) {
          return decoded['isNeed'] as bool;
        }
      } on FormatException {
        // 落入下方兼容分支。
      }
    }
    switch (raw.toLowerCase()) {
      case 'true':
        return true;
      case 'false':
        return false;
    }
    return false;
  }

  /// Step 3b：拉取一张图形验证码字节流。
  Future<Uint8List> fetchCaptcha() async {
    final url = '${config.idsOrigin}'
        '/getCaptcha.htl'
        '?${DateTime.now().millisecondsSinceEpoch}';
    final resp = await _get(url);
    if (resp.statusCode != 200) {
      throw HttpStatusException(resp.statusCode, resp.body);
    }
    if (resp.bodyBytes.isEmpty) {
      throw const HttpFailureException('getCaptcha: empty body');
    }
    return resp.bodyBytes;
  }

  /// Step 4：提交登录表单并返回最终 `Location`。
  ///
  /// 当遇到「踢出会话」提示时，会自动用页面的新 execution 二次提交。
  Future<String?> submitLogin({
    required String username,
    required String encryptedPassword,
    required String captcha,
    required String execution,
  }) async {
    final body = _buildLoginForm(
      username: username,
      encryptedPassword: encryptedPassword,
      captcha: captcha,
      execution: execution,
    );
    final resp = await _post(_loginPostUrl(), body);

    if (_isRedirect(resp.statusCode)) {
      final loc = resp.headers['location'];
      if (loc != null && loc.isNotEmpty) return loc;
    }

    if (resp.statusCode == 200) {
      final html = utf8.decode(resp.bodyBytes);
      if (html.contains('踢出会话') || html.contains('kickout')) {
        return _confirmKickoutAndGetLocation(html);
      }
      return null;
    }
    return null;
  }

  Future<String?> _confirmKickoutAndGetLocation(String html) async {
    final exec2 = extractInputValue(html, ['name="execution"']);
    if (exec2.isEmpty) {
      throw const HttpFailureException('kickout page: execution not found');
    }
    final form = 'execution=${Uri.encodeQueryComponent(exec2)}&_eventId=continue';
    final resp = await _post(_loginPostUrl(), form);
    if (_isRedirect(resp.statusCode)) {
      final loc = resp.headers['location'];
      if (loc != null && loc.isNotEmpty) return loc;
    }
    throw const HttpFailureException('kickout confirm: no Location header');
  }

  String _buildLoginForm({
    required String username,
    required String encryptedPassword,
    required String captcha,
    required String execution,
  }) {
    final enc = Uri.encodeQueryComponent(username);
    final captchaEnc = Uri.encodeQueryComponent(captcha);
    return 'username=$enc'
        '&password=$encryptedPassword'
        '&captcha=$captchaEnc'
        '&_eventId=submit'
        '&cllt=userNameLogin'
        '&dllt=generalLogin'
        '&lt='
        '&execution=${Uri.encodeQueryComponent(execution)}';
  }

  /// 登录表单 POST 目标 URL。
  ///
  /// 与 rollcall-go 对齐：固定为 `baseUrl?service=<targetService>`。
  /// 早期实现曾尝试解析 `<form action>` 再拼 service，但模板字符串
  /// `$sep=service=` 存在笔误（会变成 `?=service=`），已彻底弃用。
  String _loginPostUrl() => '${config.baseUrl}?service=$_targetService';

}

bool _isRedirect(int code) =>
    code == 301 || code == 302 || code == 303 || code == 307 || code == 308;

/// 登录页提取出的核心数据。
class IdsLoginPage {
  const IdsLoginPage({
    required this.pwdEncryptSalt,
    required this.execution,
    required this.formAction,
  });

  /// 对应页面 `<input id="pwdEncryptSalt">` 的 value，用作 AES key。
  final String pwdEncryptSalt;

  /// 对应页面 `<input name="execution">` 的 value，必须回传。
  final String execution;

  /// 登录表单 action 原文。
  final String formAction;
}
