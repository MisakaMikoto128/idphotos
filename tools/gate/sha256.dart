// tools/gate/sha256.dart
//
// 纯 Dart 的 SHA-256。属 gatekeeper 势力范围。
//
// **为什么不调 `sha256sum` 子进程**（2026-09-17）：
// 一是本仓库刚在 `grep` 上栽过 —— 从 Dart 起外部进程时，Windows 会在参数
// 传递途中静默改写内容（`\` `{` `}` `,` 被吃掉、`|` 被当管道），仪表报"没找到"
// 而不是"我看不见"。二是 `_sha256` 原来的失败模式是**静默少报**：
// 算不出来就 `return null`，调用方 `if (s != null) h[p] = s;` 于是该文件
// **从哈希表里直接消失**，不报错、不标不可判。这与条款 3/5 的 grep 事故
// 是同一个形状：**仪表失败时报告"更少"，而不是"看不到"。**
//
// 算法是标准 SHA-256（FIPS 180-4），输出与 `sha256sum` 逐位相同，
// 因此既有的 `out/hashes_*.txt` 仍然可比。

import 'dart:typed_data';

const List<int> _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

/// 计算 [message] 的 SHA-256，返回 64 位小写十六进制字符串。
String sha256Hex(List<int> message) {
  int h0 = 0x6a09e667;
  int h1 = 0xbb67ae85;
  int h2 = 0x3c6ef372;
  int h3 = 0xa54ff53a;
  int h4 = 0x510e527f;
  int h5 = 0x9b05688c;
  int h6 = 0x1f83d9ab;
  int h7 = 0x5be0cd19;

  final int ml = message.length;
  final int bitLen = ml * 8;
  final int paddedLen = ((ml + 9 + 63) ~/ 64) * 64;
  final Uint8List m = Uint8List(paddedLen);
  m.setRange(0, ml, message);
  m[ml] = 0x80;
  final ByteData bd = ByteData.view(m.buffer);
  bd.setUint32(paddedLen - 8, (bitLen ~/ 0x100000000) & 0xFFFFFFFF);
  bd.setUint32(paddedLen - 4, bitLen & 0xFFFFFFFF);

  final Uint32List w = Uint32List(64);
  for (int off = 0; off < paddedLen; off += 64) {
    for (int i = 0; i < 16; i++) {
      w[i] = bd.getUint32(off + i * 4);
    }
    for (int i = 16; i < 64; i++) {
      final int x = w[i - 15];
      final int y = w[i - 2];
      final int s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
      final int s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    int a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, hh = h7;
    for (int i = 0; i < 64; i++) {
      final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final int ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final int t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
      final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int t2 = (s0 + maj) & 0xFFFFFFFF;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
    h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF;
    h7 = (h7 + hh) & 0xFFFFFFFF;
  }

  final StringBuffer sb = StringBuffer();
  for (final int v in <int>[h0, h1, h2, h3, h4, h5, h6, h7]) {
    sb.write(v.toRadixString(16).padLeft(8, '0'));
  }
  return sb.toString();
}
