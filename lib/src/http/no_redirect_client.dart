/// 禁用自动重定向的 [http.Client] 包装。
///
/// `package:http` 的 `BaseRequest.followRedirects` 默认为 `true`，这意味着
/// `client.get/post(...)` 会把 302/301/303/307 之类的重定向自动跟到底，
/// 调用方再也看不到 `Location` 头与中间状态。
///
/// 但 CAS / LMS 登录协议里，「服务端下发的 302」本身就是要解析的信号
/// （决定下一步向哪个 URL 提交），不能让客户端自动消化掉。这与 Go 版
/// `http.Client{CheckRedirect: func(...) { return ErrUseLastResponse }}` 等价。
library;

import 'package:http/http.dart' as http;

/// 禁用自动重定向的 HTTP 客户端。
///
/// 用法：把任意 `http.Client`（包括测试用的 `MockClient`）传给构造器，
/// 然后在 `LmsClient` / `IdsHttpCore` 等需要手动处理 302 的场景下使用。
class NoRedirectClient extends http.BaseClient {
  NoRedirectClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.followRedirects = false;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
