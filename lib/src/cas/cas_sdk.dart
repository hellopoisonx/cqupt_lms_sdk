/// CQUPT 统一身份认证 (IDS) SDK。
///
/// 用法：
/// ```dart
/// final sdk = CasSdk('username', 'password');
/// final location = await sdk.login('http://jwzx.cqupt.edu.cn/...');
/// // location 是带 ticket 的回调 URL，传入浏览器或 HttpClient.Get 即可。
/// ```
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../exceptions.dart';
import 'captcha.dart';
import 'encryption.dart';
import 'http_core.dart';

/// 同步型 SDK：传入 `CaptchaSolver`，整套登录在调用方线程内串行执行。
///
/// 适用场景：CLI、桌面端、无并发登录诉求的工具。
class CasSdk {
  CasSdk(this.username, this.password, {IdsConfig? config, http.Client? client})
      : _config = config ?? const IdsConfig(),
        _client = client ?? http.Client();

  final String username;
  final String password;
  final IdsConfig _config;
  final http.Client _client;

  /// 可选同步验证码求解器。若登录要求验证码但未设置，会抛出
  /// [CaptchaRequiredException]。
  CaptchaSolver? captchaSolver;

  /// 关闭底层 [http.Client]。
  void close() => _client.close();

  /// 执行登录并返回 service 的 ticket URL（即 `Location` 响应头）。
  ///
  /// 失败可能抛出：
  /// - [CaptchaRequiredException] / [CaptchaSolveException]
  /// - [HttpFailureException] / [HttpStatusException]
  /// - [LoginFailedException]（页面未返回有效 Location）
  Future<String> login(String service) async {
    final core = IdsHttpCore.create(
      targetService: service,
      config: _config,
      client: _client,
    );
    try {
      await core.fetchGlobalCookie();
      final page = await core.fetchLoginPage();
      final encrypted = encryptPassword(password, page.pwdEncryptSalt);
      final captcha = await _resolveCaptcha(core);
      final loc = await core.submitLogin(
        username: username,
        encryptedPassword: encrypted,
        captcha: captcha,
        execution: page.execution,
      );
      if (loc == null || loc.isEmpty) {
        throw const LoginFailedException('登录失败：未收到有效 Location 头');
      }
      return loc;
    } finally {
      core.close();
    }
  }

  Future<String> _resolveCaptcha(IdsHttpCore core) async {
    final need = await core.checkNeedCaptcha(username);
    if (!need) return '';
    if (captchaSolver == null) {
      throw const CaptchaRequiredException();
    }
    final Uint8List img = await core.fetchCaptcha();
    final code = captchaSolver!(img).trim();
    if (code.isEmpty) throw const CaptchaSolveException();
    return code;
  }
}

/// 异步型 SDK：传入 `AsyncCaptchaSolver` 或纯字符串求解器。
///
/// 适用场景：Flutter / 事件循环敏感服务、需要在求解阶段挂起 IO 的环境。
class AsyncCasSdk {
  AsyncCasSdk(
    this.username,
    this.password, {
    IdsConfig? config,
    http.Client? client,
    Logger? logger,
  })  : _config = config ?? const IdsConfig(),
        _client = client ?? http.Client(),
        _log = logger ?? Logger('cqupt_lms_sdk.cas') {
    _log.onRecord.listen((record) {
      // 默认不挂 handler，避免意外打到 stdout。调用方若需要日志，
      // 自己挂 `logger.level` 和订阅。
    });
  }

  final String username;
  final String password;
  final IdsConfig _config;
  final http.Client _client;
  final Logger _log;

  /// 可选异步验证码求解器。
  AsyncCaptchaSolver? captchaSolver;

  void close() => _client.close();

  /// 执行登录并返回 service 的 ticket URL。
  Future<String> login(String service) async {
    final core = IdsHttpCore.create(
      targetService: service,
      config: _config,
      client: _client,
    );
    try {
      _log.fine('获取全局 Cookie');
      await core.fetchGlobalCookie();
      _log.fine('解析登录页');
      final page = await core.fetchLoginPage();
      _log.fine('加密密码');
      final encrypted = encryptPassword(password, page.pwdEncryptSalt);
      _log.fine('检查是否需要图形验证码');
      final captcha = await _resolveCaptcha(core);
      _log.fine('提交登录表单');
      final loc = await core.submitLogin(
        username: username,
        encryptedPassword: encrypted,
        captcha: captcha,
        execution: page.execution,
      );
      if (loc == null || loc.isEmpty) {
        throw const LoginFailedException('登录失败：未收到有效 Location 头');
      }
      _log.info('登录成功，service=$service');
      return loc;
    } finally {
      core.close();
    }
  }

  Future<String> _resolveCaptcha(IdsHttpCore core) async {
    final need = await core.checkNeedCaptcha(username);
    if (!need) return '';
    if (captchaSolver == null) {
      throw const CaptchaRequiredException();
    }
    final Uint8List img = await core.fetchCaptcha();
    final code = (await captchaSolver!(img)).trim();
    if (code.isEmpty) throw const CaptchaSolveException();
    return code;
  }
}
