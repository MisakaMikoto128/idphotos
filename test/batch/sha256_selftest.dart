// qa-batch：sha256_util.dart 的自检。
//
//   dart run test/batch/sha256_selftest.dart
//
// 三组公开测试向量 + 对真实夹具取摘要（后者与 Python hashlib 的输出逐位比对，
// 命令写在 out/P0_input_hashes.json 的 generatedBy 里）。
// 自带实现的哈希一旦算错，溯源就变成伪证，所以这个自检不是可选项。
import 'dart:convert';
import 'dart:io';

import 'sha256_util.dart';

const List<List<String>> _vectors = <List<String>>[
  <String>[
    '',
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  ],
  <String>[
    'abc',
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  ],
  <String>[
    'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
  ],
  <String>[
    'The quick brown fox jumps over the lazy dog',
    'd7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592',
  ],
];

void main() {
  var fail = 0;
  for (final v in _vectors) {
    final got = sha256Hex(utf8.encode(v[0]));
    final ok = got == v[1];
    if (!ok) fail++;
    stdout.writeln('${ok ? 'OK  ' : 'FAIL'} len=${v[0].length} '
        '${ok ? '' : 'got=$got want=${v[1]}'}');
  }
  // 百万个 'a'：压一次跨多个 block 的长输入路径。
  final million = List<int>.filled(1000000, 0x61);
  const millionWant =
      'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0';
  final millionGot = sha256Hex(million);
  final mOk = millionGot == millionWant;
  if (!mOk) fail++;
  stdout.writeln('${mOk ? 'OK  ' : 'FAIL'} 1e6 x "a" '
      '${mOk ? '' : 'got=$millionGot'}');

  // 真实文件：打印摘要，供与 Python hashlib 逐位比对。
  final dir = Directory('out/P0_anchors');
  if (dir.existsSync()) {
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files.take(3)) {
      stdout.writeln('FILE ${f.path.replaceAll('\\', '/')} '
          '${sha256Hex(f.readAsBytesSync())}');
    }
  }
  stdout.writeln(fail == 0 ? 'SELFTEST PASS' : 'SELFTEST FAIL ($fail)');
  exit(fail == 0 ? 0 : 1);
}
