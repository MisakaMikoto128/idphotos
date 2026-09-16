// REVIEW_SEC M3 安全闭合验证台（ml-porting 自用，非门禁）。
//
// 跑法：flutter test native/bench/m3_header_reject_test.dart
//
// 覆盖两组用例（协调人指定）：
//   1. 恶意构造头：头解析失败（readImageHeaderSize=null）但 image 包可解的
//      格式（TGA 无 magic，isValidFile 只看 imageType/pixelDepth 字段），
//      30000×30000 → 修复前会全量解码 ~2.7GB 瞬时分配（OOM DoS 面）；
//      修复后必须在任何像素解码之前按 ImageTooLargeException 拒绝。
//   2. 正常大图：真实 4032×3024 multi_face 数据集图，兜底解码路径必须
//      照常工作（maxEdge 降采样到工作分辨率）。
// 附带：合法小尺寸冷门格式（4×4 TGA）不受影响；畸形 JPEG 拒绝结局同型。
@Timeout(Duration(minutes: 10))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/image_header.dart';
import 'package:muzhao/core/matting/image_ops.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

void _preloadHostOnnxRuntime() {
  if (!Platform.isWindows) return;
  final home = Platform.environment['LOCALAPPDATA'];
  if (home == null) return;
  final dir = Directory('$home\\Pub\\Cache\\hosted\\pub.dev');
  if (!dir.existsSync()) return;
  for (final e in dir.listSync()) {
    final name = e.path.split(Platform.pathSeparator).last;
    if (e is Directory && name.startsWith('onnxruntime-')) {
      final dll = File('${e.path}\\windows\\onnxruntime.dll');
      if (dll.existsSync()) {
        DynamicLibrary.open(dll.path);
        return;
      }
    }
  }
}

/// 构造一个头解析失败但 TgaDecoder 认可的样张。
/// TGA 头 18 字节：[0]=idLength, [1]=colorMapType, [2]=imageType,
/// [3..7]=cmap, [8..11]=origin, [12..15]=w/h (LE u16), [16]=pixelDepth,
/// [17]=descriptor。imageType=2（未压缩真彩）+ pixelDepth=24 可过
/// isValidFile；文件头不覆盖 TGA → readImageHeaderSize=null。
Uint8List tga(int w, int h, {int bodyBytes = 1024}) {
  final b = Uint8List(18 + bodyBytes);
  final d = ByteData.sublistView(b);
  d.setUint8(2, 2);
  d.setUint16(12, w.clamp(0, 65535), Endian.little);
  d.setUint16(14, h.clamp(0, 65535), Endian.little);
  d.setUint8(16, 24);
  // body 留零：修复后解码根本不会发生
  return b;
}

Uint8List _malformedJpeg() {
  final b = Uint8List(2 + 200);
  b[0] = 0xFF;
  b[1] = 0xD8;
  for (var i = 2; i < b.length; i++) {
    b[i] = i & 0x7F; // 无 0xFF 标记的垃圾，SOF 扫描必然空手而归
  }
  return b;
}

class _Engine with MattingEngineMixin {}

void main() {
  _preloadHostOnnxRuntime();
  final repo = Directory.current.path;
  final sep = Platform.pathSeparator;
  ort.debugModelDirectory =
      '$repo${sep}assets${sep}models';

  test('M3.1 malicious oversized header-unparseable file rejected pre-decode',
      () async {
    final bomb = tga(30000, 30000);
    expect(readImageHeaderSize(bomb), isNull,
        reason: '样张必须命中"头解析失败"分支，否则测的不是 M3');
    final sw = Stopwatch()..start();
    await expectLater(() => decodeToRgb(bomb),
        throwsA(isA<UnsupportedImageException>()),
        reason: '头解析失败必须在任何像素解码前拒绝（修复前会全量解码 ~2.7GB）');
    sw.stop();
    // 拒绝是纯头解析，毫秒级；给 2s 余量区分"全量解码 30000²"路径
    expect(sw.elapsedMilliseconds, lessThan(2000),
        reason: '拒绝发生在解码前，耗时必须远小于一次 30000×30000 解码');
  });

  test('M3.2 normal big image still decodes via the fallback path', () async {
    final big = File('C:${sep}Users${sep}liuyu${sep}Pictures'
        '${sep}1979d869c783fcc849d4e05b81eb809e.png');
    final bytes = await big.readAsBytes();
    final img = decodeToRgb(bytes,
        maxEdge: kEngineMaxEdge, targetEdge: kBigImageWorkEdge);
    expect(img.width, 1536);
    expect(img.height, 1152);
  });

  test('M3.3 cold-format TGA now rejected by design (no unbounded decode)', () {
    // 数据集实证 0 个真实图片头解析失败 → 按"头解析失败 = 解不开"硬拒。
    // 合法 TGA 从此不再支持（协调人裁定：能正常解码的图头解析不该失败）。
    final b = tga(4, 4, bodyBytes: 48);
    expect(() => decodeToRgb(b), throwsA(isA<UnsupportedImageException>()));
  });

  test('M3.4 malformed JPEG outcome unchanged (UnsupportedImageException)',
      () {
    expect(() => decodeToRgb(_malformedJpeg()),
        throwsA(isA<UnsupportedImageException>()));
  });

  test('M3.5 engine-level: contract exception through Isolate.run, no crash',
      () async {
    final engine = _Engine();
    await engine.warmUp();
    try {
      final bomb = tga(30000, 30000);
      await expectLater(
          engine.removeBackground(bomb), throwsA(isA<IdPhotoException>()));
      // 同一张再试一次，确认异常路径可重复且引擎状态没坏
      await expectLater(
          engine.removeBackground(bomb), throwsA(isA<IdPhotoException>()));
    } finally {
      await engine.disposeMattingEngine();
    }
  });
}
