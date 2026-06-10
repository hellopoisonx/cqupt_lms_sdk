/// cqupt_lms_sdk 命令行入口。
///
/// 用法：
///   dart run cqupt_lms_sdk cas-login --username <u> --password <p> --service <s>
///   dart run cqupt_lms_sdk rollcalls --username <u> --password <p>
///
/// 仅作为 SDK 的最小冒烟用例。业务上请直接依赖 `package:cqupt_lms_sdk`。
library;

import 'dart:io';

import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';

const _defaultService =
    'http://jwzx.cqupt.edu.cn/tysfrz/navication.php?id=user';

Future<int> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法:');
    stderr.writeln('  cqupt_lms_sdk cas-login --username <u> --password <p> '
        '[--service <s>]');
    stderr.writeln('  cqupt_lms_sdk rollcalls --username <u> --password <p>');
    return 64;
  }
  switch (args.first) {
    case 'cas-login':
      return _casLogin(args.skip(1));
    case 'rollcalls':
      return _rollcalls(args.skip(1));
    default:
      stderr.writeln('未知子命令: ${args.first}');
      return 64;
  }
}

class _Opts {
  String? username;
  String? password;
  String? service;
}

_Opts _parseOpts(Iterable<String> args) {
  final opts = _Opts();
  final list = args.toList();
  for (var i = 0; i < list.length; i++) {
    final a = list[i];
    String? take() => i + 1 < list.length ? list[++i] : null;
    switch (a) {
      case '--username':
      case '-u':
        opts.username = take();
      case '--password':
      case '-p':
        opts.password = take();
      case '--service':
      case '-s':
        opts.service = take();
    }
  }
  opts.username ??= Platform.environment['CAS_USERNAME'];
  opts.password ??= Platform.environment['CAS_PASSWORD'];
  return opts;
}

Future<int> _casLogin(Iterable<String> args) async {
  final opts = _parseOpts(args);
  if (opts.username == null || opts.password == null) {
    stderr.writeln('缺少 --username / --password');
    return 64;
  }
  final service = opts.service ?? _defaultService;
  final sdk = CasSdk(opts.username!, opts.password!);
  try {
    final loc = await sdk.login(service);
    stdout.writeln(loc);
    return 0;
  } on SdkException catch (e) {
    stderr.writeln('登录失败: $e');
    return 1;
  } finally {
    sdk.close();
  }
}

Future<int> _rollcalls(Iterable<String> args) async {
  final opts = _parseOpts(args);
  if (opts.username == null || opts.password == null) {
    stderr.writeln('缺少 --username / --password');
    return 64;
  }
  final client = LmsClient();
  try {
    await client.login(username: opts.username, password: opts.password);
    final list = await client.getRollcalls();
    for (final r in list) {
      stdout.writeln(r);
    }
    return 0;
  } on SdkException catch (e) {
    stderr.writeln('错误: $e');
    return 1;
  } finally {
    client.close();
  }
}
