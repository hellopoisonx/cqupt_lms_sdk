## 0.2.0

- 安装方式变更：未发布到 pub.dev，仅托管在 GitHub（`https://github.com/hellopoisonx/cqupt_lms_sdk.git`），调用方需以 git 源引入。
- `Rollcall` 新增 `createdByName`（教师姓名）字段。
- 对齐 CQUPT-Rollcall-Project 参考实现：QR 提取正则优先匹配 `!3~...!4~` 闭合分隔符，无闭合时回退。
- 新增 `乒乓球馆` 坐标（指向灯光篮球场位置）。
- `isOnCall` 匹配逻辑从 `== 'on_call'` 改为 `startsWith('on_call')`，覆盖 `on_call_fine` 等 API 返回的已签到变体。
- `StudentRollcallsData` 新增 `courseTitle`、`classroom`、`teacher` 字段，补齐签到详情。
- **修复 IDS 登录失败（"未收到有效 Location 头"）**：与 rollcall-go 对齐登录链路。
  - 修复 `_resolveLoginUrl` 中 `$sep=service=` 字符串模板笔误，POST URL 不再是 `…/login?=service=…`，IDS 不再回 `exception.message=A problem occurred restoring the flow execution`。
  - `IdsHttpCore.fetchLoginPage` 不再解析 `<form action>`，POST URL 固定为 `baseUrl?service=<targetService>`。
  - `LmsClient._resolveServiceUrl` 跟 2 跳重定向（与 Go 一致），返回最终 URL 字符串本身，不再走 `lmsBase/login` 兜底。
  - `IdsConfig.userAgent` 默认值改为 Chrome/86，与 rollcall-go 一致。
  - `_baseHeaders` 不再自动加 `Origin` 头。
  - 新增 `test/login_flow_test.dart` 两条回归测试。

- 初版：复刻 CQUPT-CAS-SDK + rollcall-go 的核心客户端能力。
- CAS 登录（带图形验证码可选求解器、踢出会话二次确认）。
- LMS 客户端：登录 / 活跃签到 / 三类签到（QR/数字/雷达）/ 学生签到详情。
- QR 数据解析（15s 过期校验）。
- CQUPT 教学楼坐标匹配 + 抖动。
- 课表 API 客户端与数据模型。
- Poller：异步事件流 + 课表感知轮询 + 自动签到。
- 单元测试 36 个全通过。
- 不包含 Center WebSocket / Kitex RPC / Etcd 注册等分布式组件。
- 添加 MIT 开源许可证。
