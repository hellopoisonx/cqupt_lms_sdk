/// AES-128-CBC 密码加密。
///
/// 完整复刻 CQUPT IDS 登录页所要求的加密方式：
/// 1. 生成 64 字符随机串（密码学安全）拼接到明文前；
/// 2. 将盐（页面 `pwdEncryptSalt`）截断或补 0 到 16 字节作为 key；
/// 3. 生成 16 字符随机串作为 IV；
/// 4. AES-128-CBC + PKCS#7 填充加密；
/// 5. 输出 base64，再 url-encode 一次。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 仅使用 ASCII 字母数字，且去除视觉易混淆字符（与 Go `aesChars` 一致）。
const _chars = 'ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678';

/// 用密码学安全的随机源生成 [length] 长度的随机串。
String randomString(int length, {Random? rng}) {
  final r = rng ?? Random.secure();
  final out = List<int>.filled(length, 0);
  for (var i = 0; i < length; i++) {
    out[i] = _chars.codeUnitAt(r.nextInt(_chars.length));
  }
  return String.fromCharCodes(out);
}

/// 将任意长度 [key] 归一化到 16 字节（短则补 0，长则截断）。
Uint8List normalizeAesKey(String key) {
  final src = utf8.encode(key);
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    out[i] = i < src.length ? src[i] : 0;
  }
  return out;
}

/// PKCS#7 填充。
Uint8List pkcs7Pad(List<int> data, int blockSize) {
  final padding = blockSize - (data.length % blockSize);
  final out = Uint8List(data.length + padding);
  out.setRange(0, data.length, data);
  for (var i = data.length; i < out.length; i++) {
    out[i] = padding;
  }
  return out;
}

/// AES-128-CBC 加密（使用 [PaddedBlockCipher] + [PKCS7Padding]）。
///
/// [key] 必须正好 16 字节；[iv] 必须正好 16 字节。
Uint8List aesCbcEncrypt({
  required Uint8List plaintext,
  required Uint8List key,
  required Uint8List iv,
}) {
  if (key.length != 16) {
    throw ArgumentError.value(key.length, 'key.length', 'AES-128 key 必须是 16 字节');
  }
  if (iv.length != 16) {
    throw ArgumentError.value(iv.length, 'iv.length', 'AES-CBC iv 必须是 16 字节');
  }
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
      true,
      PaddedBlockCipherParameters<
          ParametersWithIV<KeyParameter>, CipherParameters>(
        ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
        null,
      ),
    );
  return cipher.process(plaintext);
}

/// 复刻 Go `encrypt.EncryptPasssword` 行为：
/// 输出 base64 后的 `Uri.encodeComponent` 结果（与 `url.QueryEscape` 在 ASCII
/// 范围内的编码一致）。
String encryptPassword(String password, String salt, {Random? rng}) {
  final r = rng ?? Random.secure();
  if (salt.isEmpty) {
    // 与 rollcall-go 的 crypto 行为保持一致：salt 为空时直接返回原密码。
    return password;
  }
  final randomPrefix = randomString(64, rng: r);
  final key = normalizeAesKey(salt);
  final iv = Uint8List.fromList(utf8.encode(randomString(16, rng: r)));
  final plain = Uint8List.fromList(utf8.encode(randomPrefix + password));
  final cipher = aesCbcEncrypt(plaintext: plain, key: key, iv: iv);
  return Uri.encodeComponent(base64.encode(cipher));
}
