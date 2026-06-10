# 0.1.0

- 初版：复刻 CQUPT-CAS-SDK + rollcall-go 的核心客户端能力。
- CAS 登录（带图形验证码可选求解器、踢出会话二次确认）。
- LMS 客户端：登录 / 活跃签到 / 三类签到（QR/数字/雷达）/ 学生签到详情。
- QR 数据解析（15s 过期校验）。
- CQUPT 教学楼坐标匹配 + 抖动。
- 课表 API 客户端与数据模型。
- Poller：异步事件流 + 课表感知轮询 + 自动签到。
- 单元测试 36 个全通过。
- 不包含 Center WebSocket / Kitex RPC / Etcd 注册等分布式组件。
