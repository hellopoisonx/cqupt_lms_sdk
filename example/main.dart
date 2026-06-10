// 集成示例：完整跑一遍「登录 → 拉签到 → 自动签到」流程。
//
// 运行方式（在项目根目录）：
//   fvm dart run example/main.dart --username <登录账号> --password <密码>
//                                    [--student-id <学号>]
//                                    [--curriculum-api-url <自定义课表 URL>]
//                                    [--curriculum-skip]   // 跳过课表
//
// 参数说明：
//   --username / -u         IDS 登录账号（学号、邮箱、手机号皆可）
//   --password / -p         登录密码
//   --student-id / -s       课表 API 用的学号。
//                           不传时：先用 --username 推断；
//                                  推断失败（如账号不是 10 位 l/L/数字+9 位数字）则提示并跳过课表。
//   --curriculum-api-url    自定义课表 API URL 模板（含 `{studentId}` 占位符）
//   --curriculum-skip       直接跳过课表加载
//
// 不带任何参数时仅演示 QR 解析、坐标匹配等工具能力。
import 'dart:io';

import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';

Future<int> main(List<String> args) async {
  final opts = _parseArgs(args);
  if (opts.username == null || opts.password == null) {
    _printNonLoginUsage();
    return 0;
  }

  print('=' * 50);
  print('  CQUPT LMS SDK 集成示例');
  print('=' * 50);

  // 1) 课表加载
  CurriculumData? curriculum;
  if (opts.curriculumSkip) {
    print('\n[1] 课表：已通过 --curriculum-skip 跳过');
  } else {
    final studentId = _resolveStudentId(opts);
    if (studentId == null) {
      print('\n[1] 课表：缺少有效学号（用 --student-id 显式传，或保证 '
          '--username 匹配 ^[lL\\d]\\d{9}\$）');
    } else {
      print('\n[1] 加载课表（studentId=$studentId）...');
      final api = CurriculumApi(
        studentId: studentId,
        config: opts.curriculumApiUrl == null
            ? const CurriculumApiConfig()
            : CurriculumApiConfig(endpointTemplate: opts.curriculumApiUrl!),
      );
      try {
        curriculum = await api.fetch();
        print('    课表实例数 = ${curriculum.instances.length}');
        print('    课程名集合 = ${curriculum.courses.toList()}');
      } on SdkException catch (e) {
        print('    课表加载失败（可继续）: $e');
      } finally {
        api.close();
      }
    }
  }

  // 2) IDS 登录
  print('\n[2] IDS 登录...');
  final lms = LmsClient();
  lms.onSessionEstablished = (session) {
    print('    登录成功，clientId = ${session.clientId}');
  };
  try {
    await lms.login(username: opts.username, password: opts.password);
  } on SdkException catch (e) {
    print('    登录失败: $e');
    lms.close();
    return 1;
  }

  // 3) 拉取活跃签到
  print('\n[3] 拉取活跃签到...');
  List<Rollcall> rollcalls;
  try {
    rollcalls = await lms.getRollcalls();
    if (rollcalls.isEmpty) {
      print('    当前没有活跃签到');
    } else {
      for (final r in rollcalls) {
        print('    - $r');
      }
    }
  } on SdkException catch (e) {
    print('    拉取失败: $e');
    lms.close();
    return 1;
  }

  // 4) 自动签到（基于课表 + 坐标）
  if (curriculum != null && rollcalls.any((r) => r.isAbsent)) {
    print('\n[4] 启动 Poller（30s 间隔、自动定位 + 自动数字）...');
    final poller = Poller(lms, initialCurriculum: curriculum);
    poller.events.listen((event) {
      switch (event) {
        case ActiveRollcallEvent(:final rollcall):
          print('    [event] 发现活跃签到: $rollcall');
        case CompletedRollcallEvent(:final rollcall):
          print('    [event] 签到完成: $rollcall');
        case AutoCheckinEvent(
            :final rollcall,
            :final kind,
            :final success,
            :final errorCode
          ):
          final tag = success ? '成功' : '失败($errorCode)';
          print('    [event] 自动$kind 签到$tag: $rollcall');
      }
    });
    poller.triggerPoll();
    await Future.delayed(const Duration(seconds: 5));
    await poller.close();
  } else {
    print('\n[4] 跳过 Poller（无课表或无活跃签到）');
  }

  // 5) QR 数据解析演示
  print('\n[5] QR 解析演示（构造一条合法的 hex）...');
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final sample = '$ts${'a' * 32}';
  print('    原始 hex: $sample (len=${sample.length})');
  print('    解析结果: ${extractQrData(sample)}');

  // 6) 坐标匹配演示
  print('\n[6] 坐标匹配演示...');
  for (final loc in ['2306', '综合实验楼A305', '桂花篮球场南', '未知名']) {
    final c = getLocationCoords(loc);
    print('    "$loc" -> ${c ?? "<无法识别>"}');
  }

  lms.close();
  print('\n=== 完成 ===');
  return 0;
}

/// `studentId` 与 `username` 可能不同：
/// - 优先用显式传入的 `--student-id`；
/// - 否则回退到 `--username`，但要求它形如 10 位 `^[lL\d]\d{9}$`。
String? _resolveStudentId(_Opts opts) {
  if (opts.studentId != null && opts.studentId!.isNotEmpty) {
    return opts.studentId;
  }
  final u = opts.username!;
  if (RegExp(r'^[lL\d]\d{9}$').hasMatch(u)) return u;
  return null;
}

class _Opts {
  String? username;
  String? password;
  String? studentId;
  String? curriculumApiUrl;
  bool curriculumSkip = false;
}

_Opts _parseArgs(Iterable<String> args) {
  final opts = _Opts();
  final list = args.toList();
  for (var i = 0; i < list.length; i++) {
    String? take() => i + 1 < list.length ? list[++i] : null;
    switch (list[i]) {
      case '--username':
      case '-u':
        opts.username = take();
      case '--password':
      case '-p':
        opts.password = take();
      case '--student-id':
      case '-s':
        opts.studentId = take();
      case '--curriculum-api-url':
        opts.curriculumApiUrl = take();
      case '--curriculum-skip':
        opts.curriculumSkip = true;
    }
  }
  opts.username ??= Platform.environment['CAS_USERNAME'];
  opts.password ??= Platform.environment['CAS_PASSWORD'];
  opts.studentId ??= Platform.environment['STUDENT_ID'];
  return opts;
}

void _printNonLoginUsage() {
  print('未提供账号，仅演示工具能力。\n');

  // QR
  print('QR 解析：');
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final sample = '$ts${'a' * 32}';
  print('  ${extractQrData(sample)}  <-- 合法');
  print('  ${extractQrData('garbage')}  <-- 非法\n');

  // 坐标
  print('坐标匹配：');
  for (final loc in ['2306', '综合实验楼A305', '桂花篮球场', '未识别']) {
    final c = getLocationCoords(loc);
    print('  $loc -> ${c ?? "<null>"}');
  }

  print('\n要跑完整登录流程，请传：');
  print('  --username / -u <登录账号>     （学号、邮箱、手机号皆可）');
  print('  --password / -p <密码>');
  print('  --student-id / -s <学号>     （课表 API 用，可选）');
  print('  --curriculum-api-url <URL>   （可选，含 {studentId} 占位符）');
  print('  --curriculum-skip            （可选，跳过课表）');
}
