/// HTML 字符串解析工具集。
///
/// 用于从 IDS 登录页等 HTML 中提取隐藏域值、`<form>` action 等。
/// 实现思路和 Go 端 `extractor` 完全一致：依赖纯正则，不引入 HTML 解析器依赖。
library;

/// 提取 `<input ...>` 上 `value` 属性的值。
///
/// [attrs] 是若干 `name=value` 形式的属性断言。引号部分被忽略：
/// 调用方既可传 `'id="pwdEncryptSalt"'`，也可传 `"id='pwdEncryptSalt'"`，
/// 甚至传 `"id=pwdEncryptSalt"`。value 属性的引号也兼容。
///
/// 返回空字符串表示未找到。
String extractInputValue(String html, List<String> attrs) {
  if (attrs.isEmpty) return '';
  final inputPattern = StringBuffer('<input');
  for (final attr in attrs) {
    final pair = _splitAttr(attr);
    if (pair == null) {
      inputPattern.write('(?=[^>]*$attr)');
      continue;
    }
    // 形如 name=value 时，把 name 后面的引号部分做可选匹配。
    final name = RegExp.escape(pair.$1);
    final value = RegExp.escape(pair.$2);
    inputPattern.write('(?=[^>]*\\b$name\\s*=\\s*["\']?$value["\']?)');
  }
  inputPattern.write(r'[^>]*>');

  final inputRe = RegExp(inputPattern.toString(), caseSensitive: false);
  final inputMatch = inputRe.firstMatch(html);
  if (inputMatch == null) return '';

  final valueRe = RegExp(r'''value\s*=\s*["']([^"']*)["']''',
      caseSensitive: false);
  final valueMatch = valueRe.firstMatch(inputMatch.group(0)!);
  if (valueMatch != null && valueMatch.groupCount >= 1) {
    return valueMatch.group(1) ?? '';
  }
  return '';
}

/// 提取指定 id 的 `<form>` 的 `action` 属性值。找不到返回空字符串。
String extractFormAction(String html, String formId) {
  final escapedId = RegExp.escape(formId);
  final formRe = RegExp(
    '<form[^>]*?\\bid\\s*=\\s*["\']$escapedId["\'][^>]*>',
    caseSensitive: false,
  );
  final match = formRe.firstMatch(html);
  if (match == null) return '';
  final actionRe = RegExp(r'''\baction\s*=\s*["']([^"']*)["']''',
      caseSensitive: false);
  final actionMatch = actionRe.firstMatch(match.group(0)!);
  if (actionMatch != null && actionMatch.groupCount >= 1) {
    return actionMatch.group(1) ?? '';
  }
  return '';
}

/// 按顺序尝试多个 form id，返回第一个非空 action。
String extractAnyFormAction(String html, List<String> formIds) {
  for (final id in formIds) {
    final action = extractFormAction(html, id);
    if (action.isNotEmpty) return action;
  }
  return '';
}

/// 把 `'id="foo"'` / `"id='foo'"` / `'id=foo'` 解析为 `(name, value)`。
/// 不是 `name=value` 形式则返回 null。
(String, String)? _splitAttr(String attr) {
  final eq = attr.indexOf('=');
  if (eq < 0) return null;
  final name = attr.substring(0, eq).trim();
  var value = attr.substring(eq + 1).trim();
  if (value.length >= 2) {
    final first = value[0];
    final last = value[value.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      value = value.substring(1, value.length - 1);
    }
  }
  return (name, value);
}
