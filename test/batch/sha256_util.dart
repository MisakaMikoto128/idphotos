// qa-batch：无外部依赖的 SHA-256，用于给「喂给引擎的输入字节」取指纹。
//
// 为什么不用 package:crypto：它是 pubspec.lock 里的**传递依赖**，没有在
// pubspec.yaml 的 dependencies 里声明（pubspec.yaml 归主会话独占）。引用未声明的
// 传递依赖能在当前 lock 下跑通，但 lock 一变就会静默失效——对溯源工具来说
// "静默失效"是最坏的失败模式。所以这里自带一份实现，并由
// test/batch/sha256_selftest.dart 用公开测试向量钉死正确性。
library;

import 'dart:typed_data';

const List<int> _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

/// 返回 64 位小写十六进制摘要。
String sha256Hex(List<int> message) {
  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];

  final ml = message.length;
  final bitLen = ml * 8;
  // 填充：0x80，补 0 到 56 mod 64，再写 8 字节大端长度。
  final total = ((ml + 9 + 63) ~/ 64) * 64;
  final buf = Uint8List(total);
  buf.setRange(0, ml, message);
  buf[ml] = 0x80;
  final bd = ByteData.view(buf.buffer);
  bd.setUint32(total - 8, (bitLen ~/ 0x100000000) & 0xFFFFFFFF);
  bd.setUint32(total - 4, bitLen & 0xFFFFFFFF);

  final w = Uint32List(64);
  for (var off = 0; off < total; off += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = bd.getUint32(off + i * 4);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rr(w[i - 15], 7) ^ _rr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rr(w[i - 2], 17) ^ _rr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rr(e, 6) ^ _rr(e, 11) ^ _rr(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rr(a, 2) ^ _rr(a, 13) ^ _rr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    h[0] = (h[0] + a) & 0xFFFFFFFF;
    h[1] = (h[1] + b) & 0xFFFFFFFF;
    h[2] = (h[2] + c) & 0xFFFFFFFF;
    h[3] = (h[3] + d) & 0xFFFFFFFF;
    h[4] = (h[4] + e) & 0xFFFFFFFF;
    h[5] = (h[5] + f) & 0xFFFFFFFF;
    h[6] = (h[6] + g) & 0xFFFFFFFF;
    h[7] = (h[7] + hh) & 0xFFFFFFFF;
  }
  final sb = StringBuffer();
  for (final v in h) {
    sb.write(v.toRadixString(16).padLeft(8, '0'));
  }
  return sb.toString();
}
