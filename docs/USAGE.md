# cqupt_lms_sdk 调用方指南

> 本文档面向**集成方**——拿到这个 SDK 之后怎么接、怎么避坑、怎么拓展。
> 不重复讲内部实现；要追代码去看源文件顶部的 doc 注释。

## 0. 定位与边界

- **本 SDK 提供什么**：CAS 单点登录、LMS 活跃签到拉取、三类签到提交（QR / 数字 / 雷达）、学生签到详情、QR 解析、教学楼坐标匹配、课表拉取、**课表感知的轮询 + 自动签到主循环**。所有公开 API 都是异步的（`Future` / `Stream`）。
- **本 SDK 不提供什么**：
  - **Center WebSocket 共享**：多人共享签到需要另写 `CenterClient`（或用现成的）。
  - **HTTP 服务壳**：要给手机/前端暴露 API，自己起 `shelf` / `dart_frog` / `conduit`。
  - **代理热更新**：`package:http` 运行时改不了代理；如需"运行时切代理"得自己包一层可重建的 client。
  - **验证码 OCR**：SDK 只暴露 `Future<String> Function(Uint8List)` 钩子，调用方自己接 ddddocr / 远程打码。

如果你要复刻 `CQUPT-Rollcall-Project/edge_server` 的"Edge 节点"——单机部分全覆盖；"Center 客户端 + HTTP API"两件是上层事。

---

## 1. 安装

SDK **未发布到 pub.dev**，仅托管在 GitHub 私有仓库。在调用方 `pubspec.yaml` 中以 git 源引入：

```yaml
dependencies:
  cqupt_lms_sdk:
    git:
      url: https://github.com/hellopoisonx/cqupt_lms_sdk.git
      ref: v0.2.0   # tag / branch / commit 任选
```

需要本地联调时改用 `path`：

```yaml
dependencies:
  cqupt_lms_sdk:
    path: ../cqupt_lms_sdk
```

> Dart `^3.12.0`；运行时仅有 `http` / `crypto` / `collection` / `logging` / `pointycastle` 五个外部依赖，无原生插件——桌面端、服务器端、Flutter 端通吃。

---

## 2. 最短路径：登录 + 拉签到

```dart
import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';

Future<void> main() async {
  final lms = LmsClient();

  // 1. 登录
  final ok = await lms.login(username: '2020210100', password: '...');
  if (!ok) throw StateError('登录失败');

  // 2. 拉活跃签到
  final rollcalls = await lms.getRollcalls();
  for (final r in rollcalls) {
    print('id=${r.rollcallId} type=${r.source} status=${r.status} '
        'course=${r.courseTitle} teacher=${r.createdByName}');
  }

  lms.close();
}
```

完整流程的内部状态机见 `lib/src/lms/lms_client.dart`。要点：

- `LmsClient` 内部**串行化**所有请求（`_SerialQueue`），并发调用安全但不会并发执行。
- `getRollcalls()` 在拿到 302/401 时**会自动重登**（如已注入密码 / 持久化 session）。这是默认行为；若你想关掉，传 `autoRelogin: false`。
- 同一进程内**只应持有一个** `LmsClient` 实例——cookie jar 是实例字段，多实例 = 多份 cookie。

---

## 3. Cookie 持久化（重启免登录）

`LmsClient` 不直接落盘，暴露两个 callback：

```dart
final lms = LmsClient();

// 登录成功后：把 session 写到本地
lms.onSessionEstablished = (session) async {
  // session.toJson() 是稳定结构（client_id / username / cookies / saved_at）
  await File('data/cookies.json').writeAsString(jsonEncode(session.toJson()));
  print('session saved: clientId=${session.clientId} '
        'cookies=${session.cookies.length}');
};

// 启动时：把 session 读回来
final raw = File('data/cookies.json').readAsStringSync();
if (raw.isNotEmpty) {
  lms.restoreSession(LmsSession.fromJson(jsonDecode(raw)));
}

// 重启后：只调用 getRollcalls 即可触发自动重登（如服务端 cookie 还在）
final rollcalls = await lms.getRollcalls();
```

**关键不变量**：

- `onSessionEstablished` 回调里拿到的 `LmsSession` 是**快照**——`LmsClient` 后续不会再修改你引用它；存什么值由你决定。
- 内部自动重登时**不会**触发 `onSessionEstablished`（避免用新 cookie 覆盖你刚存的旧 session）。如果你看到 `cookies.json` 写了很多次，多半是手动调了 `login()` 而不是靠自动重登。
- `LmsSession.clientId` 在每次新建 `LmsClient` 时**会重新生成**——如果你想长期复用同一个 ID（Center 注册、签到指纹等场景需要），必须在 `restoreSession` 之后回写 `lms.clientId = session.clientId`。

---

## 4. 三类签到

```dart
// 1. QR 签到
final raw = await scanner.scan(); // 假设你扫到一个原始串
final hex = extractQrData(raw);   // 提取 42 位 hex；空串 = 过期/无效
if (hex.isEmpty) {
  print('QR 过期或格式不对');
  return;
}
final r = await lms.doCheckin(rollcallId, 'qr', {'data': hex});

// 2. 数字签到
final r = await lms.doCheckin(rollcallId, 'number', {'numberCode': '1234'});

// 3. 雷达签到
final coord = getLocationCoords('2306'); // 教学楼 2 教 3 楼教室
if (coord != null) {
  final r = await lms.doCheckin(rollcallId, 'radar', {
    'lat': coord.lat,
    'lon': coord.lon,
  });
}

// 检查结果
if (r.success) {
  print('签到成功');
} else {
  print('签到失败: code=${r.errorCode}');
}
```

返回结构是 `CheckinResult { success, errorCode }`。`errorCode` 优先取 API 的 `error_code` 字段，缺失时回退到 `message`。常见值：`qr_code_expired` / `rollcall_expired` / `not_in_range` / `already_checked_in` 等。

### QR 解析的两个坑

`extractQrData` 内部已经处理：

1. **15 秒过期**：服务端只接受 15 秒内的 QR，时间戳来自 hex 前 10 位。
2. **URL/纯 hex 两种格式**：  
   - `/j?p=...!3~<hex>!4~...`：优先 `!3~…!4~` 闭合匹配；无闭合时回退 `!3~<hex>`。  
   - 纯 42 位 hex 也接受。  
   - 长度不是 42、含非 hex 字符、过期——全部返回空串。

调用方判断合法用 `hex.isNotEmpty`；不必自己再写正则。

### 坐标匹配

`getLocationCoords(String locationName)` 支持：

- **4 位数字教室号**（如 `2306`）：取首字符到教学楼坐标（`1`/`2`/`3`/`4`/`5`/`8`/`9`）。
- **关键字匹配**：教学地点里包含 `综合实验楼A` / `桂花篮球场` / `灯光篮球场` / `风华运动场` / `太极运动场` / `乒乓球馆` / `综合实验楼B` / `综合实验楼C` 即命中。
- **±20m 抖动**：内部 `Random`，每次调用结果不同；不需要你自己加。
- **命中失败返回 `null`**——本 SDK **不**实现"未匹配时随机兜底 ±100m"。若需要兜底，自行：

```dart
Coordinate? coord = getLocationCoords(locationName);
coord ??= _fallbackRandom(rng: Random());
// ...

Coordinate _fallbackRandom({required Random rng, double offsetMeters = 100}) {
  final positions = [
    const Coordinate(29.531049, 106.605647), // 1教
    // ... 或复用 buildings.dart 里的常量
  ];
  final base = positions[rng.nextInt(positions.length)];
  final latOff = (rng.nextDouble() - 0.5) * 2 * offsetMeters / 111320;
  final lonOff = (rng.nextDouble() - 0.5) * 2 * offsetMeters / 111320;
  return Coordinate(base.lat + latOff, base.lon + lonOff);
}
```

---

## 5. 课表感知轮询 + 自动签到

```dart
final curriculum = await CurriculumApi(studentId: '2020210100').fetch();

final poller = Poller(
  lms,
  initialCurriculum: curriculum,
  config: const PollerConfig(
    pollInterval: Duration(seconds: 30),
    curriculumPreMinutes: 10,
    autoLocationCheckin: true,
    autoNumberCheckin: true,
  ),
);

// 订阅事件
poller.events.listen((e) {
  switch (e) {
    case ActiveRollcallEvent(:final rollcall):
      print('发现活跃签到: $rollcall');
    case CompletedRollcallEvent(:final rollcall):
      print('签到完成: $rollcall');
    case AutoCheckinEvent(:final rollcall, :final kind, :final success, :final errorCode):
      print('自动 $kind: success=$success code=$errorCode');
  }
});

// 启动（阻塞；放 isolate / isolate supervisor / 后台任务里）
await poller.run();
```

行为细节：

- **窗口判断**：若 `curriculum` 非空，只在每节课「课前 N 分钟（`curriculumPreMinutes`）至课末」内轮询；空课表使用默认三段式窗口 `7:50-12:00 / 13:50-18:00 / 18:50-22:40`。
- **自动雷达**：用"当前正在进行的课程"地点 → 坐标 → 提交。判定"当前课程"的口径是 `start_time - 15min ≤ now ≤ end_time`。
- **自动数字**：先拉 `getStudentRollcalls(id)`，只有当 `isNumber && numberCode 非空 && 至少 1 人 on_call` 才提交。
- **`triggerPoll()`**：签到成功后立即再拉一次（不等 30s）。外部业务（如 Center 推来共享签到）也应当调它。
- **错误重试**：连续 `_maxConsecutiveErrors`（默认 3）次 `getRollcalls` 失败后，`run()` 抛异常——可在外层捕获后决定是否 `await poller.run()` 重启。

要把 Poller 跑成后台守护，推荐用 `Isolate.spawn` 或自己起一个 `Timer.run` 形式的入口。**别在主 isolate 短任务里 `await poller.run()`**——它会一直跑到 `poller.stop()`。

---

## 6. 异常模型

| 异常类 | 触发条件 | 调用方应做 |
|---|---|---|
| `HttpFailureException` | 网络层（DNS / 连接被拒 / 超时 / 重试耗尽） | 通常重试；检查网络/代理 |
| `HttpStatusException(statusCode, body)` | 业务非 2xx | 看状态码；4xx 多半是请求错，5xx 走重试 |
| `CaptchaRequiredException` | IDS 要求图形验证码但未注册 `onCaptchaRequired` | 注册 solver（见 §7） |
| `CaptchaSolveException` | solver 返回空串 | 切渠道或人工介入 |
| `LoginFailedException` | 登录收尾未拿到 session cookie | 检查账密 / 验证码 / IDS 风控 |
| `CheckinErrorException` | `doCheckin` 显式抛——SDK 实际上把它降级为 `CheckinResult(success:false, errorCode:...)`，**不抛** | 看 `errorCode` |
| `InvalidQrDataException` | `extractQrData` 失败时**不抛**，返回空串 | 见 §4 |
| `PollerAlreadyRunningException` | 重复调 `run()` | 状态机错误，先 `close()` 再起新实例 |

所有异常继承 `SdkException`，外层 `try / on SdkException` 可兜底。

---

## 7. 验证码求解器

```dart
// 异步版（推荐；不要在同步上下文里跑 OCR）
lms.onCaptchaRequired = (img) async {
  // img 是 JPEG 字节流
  final path = '${Directory.systemTemp.path}/captcha_${DateTime.now().millisecondsSinceEpoch}.jpg';
  await File(path).writeAsBytes(img);
  print('请打开 $path 输入验证码');
  return stdin.readLineSync() ?? '';
};

// 同步版（CLI）
final syncSdk = CasSdk('user', 'pass');
syncSdk.captchaSolver = (img) {
  // 自己写文件 / OCR / 远程打码
  return 'abcd';
};
final loc = await syncSdk.login('http://jwzx.cqupt.edu.cn/...');
```

不传 solver 又遇到验证码 → `CaptchaRequiredException`。

---

## 8. 仅用 CAS 登录（不挂 LMS）

若你的目标 service 不是 LMS（比如教务系统）：

```dart
final cas = AsyncCasSdk('学号', '密码');
cas.captchaSolver = (img) async => 'abcd';
final ticketUrl = await cas.login('http://jwzx.cqupt.edu.cn/tysfrz/navication.php?id=user');
// ticketUrl 长这样：http://jwzx.cqupt.edu.cn/...?ticket=ST-...
// 拿浏览器打开 / 用 HttpClient 跟到底即可拿到教务系统的 session
cas.close();
```

同步版 `CasSdk` 用法一致（`captchaSolver` 是同步函数）。

---

## 9. 调试日志

```dart
import 'package:logging/logging.dart';

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((r) {
    print('[${r.level.name}] ${r.loggerName}: ${r.message}');
  });
  // ...
}
```

日志来自两个命名空间：`cqupt_lms_sdk.lms`（LMS 客户端）和 `cqupt_lms_sdk.poller`（Poller）。CAS SDK 还有一个 `cqupt_lms_sdk.cas`。`Level.ALL` 会输出 HTTP 请求的 `Cookie` 头——**别把日志发到生产 stdout**，里头有 session。

---

## 10. 自定义 HTTP 客户端

想接代理、加中间件、做 mTLS 抓包——把 `http.Client` 注入：

```dart
final client = IOClient(HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:7890;');
final lms = LmsClient(client: client);
// CurriculumApi 也吃 client：
final curriculum = await CurriculumApi(studentId: '...', client: client).fetch();
```

> `package:http` 一旦创建不可改代理；要在运行时切换，**关掉旧 client → 新建 LmsClient**。

---

## 11. 常见坑

1. **`LmsClient.close()` 之后别再调用任何方法**——`http.Client` 已关，下一次调用抛 `ClientException`。每个 `LmsClient` 对应一个 `try { ... } finally { lms.close(); }`。
2. **课表 API 走的是第三方 (`cqupt.ishub.top`)**——它不是学校官方服务，挂掉时 `CurriculumApi.fetch()` 抛 `HttpStatusException` / `HttpFailureException`，`Poller` 会进入"无课表默认窗口"模式继续轮询，不会卡死。
3. **不要把 `lms` 传给多个 Poller**——两个 Poller 会争抢 `getRollcalls` 的结果、去重 map 也分裂。Poller 与 LmsClient 1:1。
4. **`extractQrData` 第二次以上调用**——内部无状态，可任意并发；不要缓存"解析过的 rawQR"——过期判定依赖当前时间。
5. **`Rollcall.isOnCall` 用的是 `startsWith('on_call')`**——`on_call_fine`（已签到 + 状态正常）也视为已签。不要写 `status == 'on_call'`。
6. **不要绕过 `doCheckin` 自己拼 PUT 请求**——SDK 内部会自动注入 `deviceId`（rollcall-go 协议要求）；漏掉这个字段服务端可能拒签。
7. **Center 共享不在本 SDK**。若你的场景需要"同教室一人扫码全员签到"，得自己写 WS 客户端：连 Center → 收到 `rollcall_share` → 调 `lms.doCheckin(...)` → 回 `rollcall_share_verification`。Poller 已经把"提交签到 + 后续状态"封装好，不要在 WS 客户端里再写一遍签到流程。
8. **`HttpStatusException` 的 body 字段最长 200 字符**——抓全量响应体去自己的日志器抓，本 SDK 不持久化响应内容。

---

## 12. 端到端骨架（CLI / 服务都适用）

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';
import 'package:logging/logging.dart';

const _cookieFile = 'data/cookies.json';

Future<void> main(List<String> args) async {
  Logger.root.level = args.contains('-v') ? Level.ALL : Level.INFO;
  Logger.root.onRecord.listen((r) => stderr.writeln('[${r.level.name}] ${r.message}'));

  final username = args[0];
  final password = args[1];

  final lms = LmsClient();

  // 1. 恢复上次 session
  final file = File(_cookieFile);
  if (file.existsSync()) {
    lms.restoreSession(LmsSession.fromJson(jsonDecode(file.readAsStringSync())));
  }

  // 2. 登录 + 持久化
  lms.onSessionEstablished = (s) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(s.toJson()));
  };
  await lms.login(username: username, password: password);

  // 3. 拉课表 + 启 Poller
  final curriculum = await CurriculumApi(studentId: username).fetch();
  final poller = Poller(lms, initialCurriculum: curriculum);
  poller.events.listen((e) => stderr.writeln('event: $e'));

  // 4. 优雅退出
  ProcessSignal.sigint.watch().listen((_) async {
    stderr.writeln('shutting down...');
    await poller.close();
    lms.close();
    exit(0);
  });

  await poller.run();
}
```

到这步你已经是一个单机 Edge 节点；接入 Center 共享只需要在 `poller.events` 同层再起一个 `CenterClient.listen(...)` 监听远端消息并调 `lms.doCheckin(...)` / `poller.triggerPoll()`。

---

## 13. SDK 不做的事（明确清单）

- ❌ Center WebSocket 客户端
- ❌ FastAPI / Shelf / Conduit 等 HTTP 服务壳
- ❌ Docker 镜像 / 部署脚本
- ❌ 验证码 OCR（仅暴露钩子）
- ❌ 持久化存储（`cookies.json` 落盘由调用方三行代码完成）
- ❌ 代理热更新（需自己包一层可重建的 client）
- ❌ 兜底随机 ±100m 坐标（`getLocationCoords` 未命中时返回 `null`；5 行代码自补）
- ❌ 课表 30 分钟磁盘缓存（`CurriculumApi` 每次直打；外部 5 行加 `Future<CurriculumData>?` 即可）
