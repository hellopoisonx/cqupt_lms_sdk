# cqupt_lms_sdk

重庆邮电大学统一身份认证 (CAS) + LMS 签到 Dart SDK。

> 复刻 [CQUPT-CAS-SDK](https://github.com/Auto-CQUPT-Plan/CQUPT-CAS-SDK) 与
> [rollcall-go](https://github.com/Auto-CQUPT-Plan/rollcall-go) 的核心能力，并按 Dart
> 习惯调整为全异步 API。

## 模块

| 模块 | 路径 | 作用 |
|---|---|---|
| CAS | `src/cas/` | IDS 登录；返回任意 service 的 ticket URL |
| LMS | `src/lms/` | 登录、签到列表、QR/数字/雷达签到、学生签到详情 |
| QR | `src/qr/` | 解析 QR 码原始 hex（含 15s 过期） |
| 坐标 | `src/location/` | CQUPT 教学楼 / 运动场 / 实验楼坐标匹配 + 抖动 |
| 课表 | `src/curriculum/` | 课表模型 + 社区 API 拉取 |
| Poller | `src/poller/` | 课表感知轮询 + 自动签到 + 事件流 |

> 本项目**不含** Center WebSocket / Kitex RPC / Etcd 注册等分布式组件。  
> 共享签到请直接以 WebSocket 自行接 Center，或上层另起服务。

## 安装

```yaml
dependencies:
  cqupt_lms_sdk:
    path: .
```

要求 Dart `^3.12.0`。

## 快速开始

### 仅 CAS 登录

```dart
import 'package:cqupt_lms_sdk/cqupt_lms_sdk.dart';

final sdk = CasSdk('学号', '密码');
final loc = await sdk.login('http://jwzx.cqupt.edu.cn/tysfrz/navication.php?id=user');
print(loc); // http://.../navication.php?id=user&ticket=ST-...
sdk.close();
```

### IDS + LMS 全流程

```dart
final lms = LmsClient();
lms.onSessionEstablished = (session) {
  // 可在此持久化 cookie，下次通过 restoreSession() 恢复
};
await lms.login(username: '学号', password: '密码');
final rollcalls = await lms.getRollcalls();
for (final r in rollcalls) {
  print(r);
}
lms.close();
```

### 三种签到

```dart
// QR 签到
final qr = extractQrData('https://.../j?p=foo!3~<42位hex>!4~bar');
if (qr.isNotEmpty) {
  final res = await lms.doCheckin(rollcallId, 'qr', {'data': qr});
}

// 数字签到
final res = await lms.doCheckin(rollcallId, 'number', {'numberCode': '1234'});

// 雷达签到（先解析坐标）
final coord = getLocationCoords('2306'); // 教学楼编号匹配
if (coord != null) {
  final res = await lms.doCheckin(rollcallId, 'radar', {
    'lat': coord.lat,
    'lon': coord.lon,
  });
}
```

### 异步 Poller（课表感知 + 自动签到）

```dart
final curriculum = await CurriculumApi().fetch();
final poller = Poller(lms, initialCurriculum: curriculum);
poller.events.listen((event) {
  switch (event) {
    case ActiveRollcallEvent(:final rollcall):
      print('发现活跃签到: $rollcall');
    case CompletedRollcallEvent(:final rollcall):
      print('签到完成: $rollcall');
    case AutoCheckinEvent(:final rollcall, :final kind, :final success, :final errorCode):
      print('自动$kind 签到: $rollcall, success=$success, code=$errorCode');
  }
});
poller.triggerPoll(); // 立即触发一次
await poller.run();   // 阻塞；或包到自己的 Zone / Future 中
```

## CLI

```bash
fvm dart run bin/cqupt_lms_sdk.dart cas-login --username <u> --password <p>
fvm dart run bin/cqupt_lms_sdk.dart rollcalls --username <u> --password <p>
```

或设置环境变量 `CAS_USERNAME` / `CAS_PASSWORD` 后直接 `fvm dart run bin/cqupt_lms_sdk.dart rollcalls`。

## 集成示例

```bash
fvm dart run example/main.dart --username <学号> --password <密码>
```

不带参数时只演示 QR 解析、坐标匹配等工具能力。

## 测试

```bash
fvm dart test
```

## 与 Go 版的差异

| 项 | Go | Dart |
|---|---|---|
| 并发模型 | goroutine + 锁 | `Future` + 内部串行队列 |
| 事件通知 | 同步回调 | `Stream<PollerEvent>` 广播流 |
| Cookie 管理 | `net/http/cookiejar` | 自维护 `Map<host, Map<name, Cookie>>` |
| 加密 | 标准库 `crypto/aes` | `pointycastle` (AES-128-CBC + PKCS#7) |
| 验证码求解 | 函数签名 | 同步 `CaptchaSolver` + 异步 `AsyncCaptchaSolver` 双接口 |
| HTTP 客户端 | `http.Client` | `package:http` |
| Center 共享 | 官方内置 | **不包含**（按需求剔除） |

## 许可证

本项目基于 [MIT License](LICENSE) 开源。

仅供学习与个人自动化使用，请遵守学校相关规章制度。

