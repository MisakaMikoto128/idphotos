// ml-porting 自用：抠图**成片**质量肉眼探针（不是门禁）。
//
// 跑法（Windows，仓库根目录）：
//   flutter test native/bench/matte_quality_probe_test.dart
//
// 它把 C:\Users\liuyu\Pictures\ 里的真实人像过一遍引擎，按用户实际看到的
// 形态出图：alpha 合成到白/红/蓝底上，再按人脸框裁出"头肩"区域，
// 拼成 [原图 | alpha | 白底 | 红底] 四联图，逐张写到临时目录。
// 另外出一组**边缘放大**图（发丝/衣领轮廓 4× 最近邻），专看锯齿与色溢。
//
// 产物目录：系统临时目录/muzhao_matte_q/，不落进仓库。
@Timeout(Duration(minutes: 60))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
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

class _Engine with MattingEngineMixin {}

/// 用户的素材目录（CLAUDE.md §5.5）。
const String _pics = r'C:\Users\liuyu\Pictures';

/// 人像样本。名字 → 文件。挑的是各类难例。
const Map<String, String> _samples = <String, String>{
  'p_2': r'2.jpg', // 蓝底白衬衫，发梢细碎
  'p_29': r'29EDA59B982FA8339335D50B00CCD096.jpg', // 蓝底白衬衫，半身
  'p_8d': r'8D861A29F86CE7464865EFEB3C9B4124.jpg', // 同上另一个尺寸
  'p_a': r'a.jpg', // 小图 483×604
  'p_wu': r'吴港+通信工程+532128200107160711.jpg', // 480×640 报名照
  'p_bm': r'报名照片.jpg', // 295×413，已经是成品一寸
  'p_1x2': r'1 (2).jpg', // 2880×4982 大图
  'p_cam1': r'Camera Roll\WIN_20230522_00_19_11_Pro.jpg', // 1280×720 摄像头
  'p_cam2': r'Camera Roll\WIN_20230522_00_19_21_Pro.jpg',
};

final int _bgWhite = 0xFFFFFFFF;
final int _bgRed = 0xFFD9001B;
final int _bgBlue = 0xFF438EDB;

img.Image _toImg(Uint8List gray, int w, int h) {
  final im = img.Image(width: w, height: h, numChannels: 1);
  im.getBytes(order: img.ChannelOrder.red).setAll(0, gray);
  return im;
}

/// 单通道放大 [f] 倍（最近邻），看锯齿/阶梯用。
img.Image _zoom(img.Image src, int f) {
  final out = img.Image(
      width: src.width * f, height: src.height * f, numChannels: src.numChannels);
  for (var y = 0; y < out.height; y++) {
    for (var x = 0; x < out.width; x++) {
      final p = src.getPixel(x ~/ f, y ~/ f);
      out.setPixel(x, y, p);
    }
  }
  return out;
}

/// RGBA + alpha 合成到纯色底，返回 RGB 图。
img.Image _composite(Uint8List rgba, Uint8List alpha, int w, int h, int bg) {
  final br = (bg >> 16) & 0xFF, bgc = (bg >> 8) & 0xFF, bb = bg & 0xFF;
  final out = img.Image(width: w, height: h, numChannels: 3);
  for (var i = 0, j = 0; i < w * h; i++, j += 4) {
    final a = alpha[i];
    final inv = 255 - a;
    out.setPixelRgb(
      i % w,
      i ~/ w,
      (rgba[j] * a + br * inv) ~/ 255,
      (rgba[j + 1] * a + bgc * inv) ~/ 255,
      (rgba[j + 2] * a + bb * inv) ~/ 255,
    );
  }
  return out;
}

/// 头肩裁剪框（工作分辨率坐标），按人脸框推算 —— 与用户实际看到的构图接近。
List<int> _headCrop(img.Image im, FaceInfo? face) {
  final int w = im.width, h = im.height;
  if (face == null) {
    return <int>[0, 0, w, h];
  }
  final fx = face.box.left, fy = face.box.top;
  final fw = face.box.width, fh = face.box.height;
  final cx = fx + fw / 2;
  // 头顶往上留 1.2 个脸高，下巴往下留 1.4 个脸高（含肩）
  var top = (fy - 1.15 * fh).round();
  var bottom = (fy + fh + 1.5 * fh).round();
  var left = (cx - 1.35 * fw).round();
  var right = (cx + 1.35 * fw).round();
  if (bottom - top < 1) bottom = top + 1;
  if (right - left < 1) right = left + 1;
  return <int>[
    left.clamp(0, math.max(0, w - 1)),
    top.clamp(0, math.max(0, h - 1)),
    right.clamp(1, w),
    bottom.clamp(1, h),
  ];
}

void main() {
  final repo = Directory.current.path;
  final outDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}muzhao_matte_q')
    ..createSync(recursive: true);
  late _Engine engine;

  setUpAll(() async {
    _preloadHostOnnxRuntime();
    ort.debugModelDirectory =
        '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';
    engine = _Engine();
    await engine.warmUp();
    stdout.writeln('provider = ${engine.mattingProvider}');
    stdout.writeln('out = ${outDir.path}');
  });

  tearDownAll(() => engine.disposeMattingEngine());

  test('成片质量肉眼探针', () async {
    for (final e in _samples.entries) {
      final path = '$_pics${Platform.pathSeparator}${e.value}';
      final f = File(path);
      if (!f.existsSync()) {
        stdout.writeln('${e.key}: MISSING $path');
        continue;
      }
      final bytes = f.readAsBytesSync();
      final sw = Stopwatch()..start();
      final MattingResult r;
      try {
        r = await engine.removeBackground(bytes);
      } on IdPhotoException catch (ex) {
        stdout.writeln('${e.key}: REJECT ${ex.runtimeType} ${ex.cause}');
        continue;
      }
      final ms = sw.elapsedMilliseconds;
      // removeBackground 刚对同一实例检过脸，这里必然命中单槽缓存。
      final face = await engine.detectFace(bytes);
      final crop = _headCrop(
          img.Image(width: r.width, height: r.height, numChannels: 3), face);
      final x0 = crop[0], y0 = crop[1];
      final cw = crop[2] - crop[0], ch = crop[3] - crop[1];

      // 源图（同坐标系）直接用引擎返回的 rgba
      final srcImg = img.Image(width: r.width, height: r.height, numChannels: 3);
      for (var i = 0, j = 0; i < r.width * r.height; i++, j += 4) {
        srcImg.setPixelRgb(i % r.width, i ~/ r.width, r.rgba[j], r.rgba[j + 1],
            r.rgba[j + 2]);
      }
      final alphaImg = _toImg(r.alpha, r.width, r.height);
      final whiteImg = _composite(r.rgba, r.alpha, r.width, r.height, _bgWhite);
      final blueImg = _composite(r.rgba, r.alpha, r.width, r.height, _bgBlue);
      final redImg = _composite(r.rgba, r.alpha, r.width, r.height, _bgRed);

      const labels = <String>['src', 'alpha', 'white', 'blue', 'red'];
      final imgs = <img.Image>[
        srcImg,
        alphaImg,
        whiteImg,
        blueImg,
        redImg
      ];
      final w = cw, h = ch;
      final sheet =
          img.Image(width: w * imgs.length, height: h, numChannels: 3);
      for (var k = 0; k < imgs.length; k++) {
        final im = imgs[k];
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final p = im.getPixel(x0 + x, y0 + y);
            sheet.setPixel(x * imgs.length * 0 + k * w + x, y, p);
          }
        }
      }
      File('${outDir.path}${Platform.pathSeparator}${e.key}_sheet.png')
          .writeAsBytesSync(img.encodePng(sheet));

      // 边缘放大：取发梢/肩线附近一小块，2× 看锯齿
      final ez = 180;
      final ex = (face == null
              ? 0
              : (face.box.left + face.box.width / 2).round() - ez ~/ 2)
          .clamp(0, math.max(0, r.width - ez))
          .toInt();
      final ey = (face == null
              ? 0
              : (face.box.top - face.box.height * 0.35).round())
          .clamp(0, math.max(0, r.height - ez))
          .toInt();
      final cropImgs = <img.Image>[
        srcImg,
        redImg,
        whiteImg
      ];
      final zs = <img.Image>[];
      for (final im in cropImgs) {
        final c = img.Image(width: ez, height: ez, numChannels: 3);
        for (var y = 0; y < ez; y++) {
          for (var x = 0; x < ez; x++) {
            c.setPixel(x, y, im.getPixel(ex + x, ey + y));
          }
        }
        zs.add(_zoom(c, 3));
      }
      final edge = img.Image(
          width: zs[0].width * zs.length, height: zs[0].height, numChannels: 3);
      for (var k = 0; k < zs.length; k++) {
        for (var y = 0; y < zs[0].height; y++) {
          for (var x = 0; x < zs[0].width; x++) {
            edge.setPixel(k * zs[0].width + x, y, zs[k].getPixel(x, y));
          }
        }
      }
      File('${outDir.path}${Platform.pathSeparator}${e.key}_edge.png')
          .writeAsBytesSync(img.encodePng(edge));

      // 定量：边缘半透明像素里的"背景色残留"（蓝底照里 B−R 明显偏高）
      var spill = 0, semi = 0;
      for (var i = 0, j = 0; i < r.width * r.height; i++, j += 4) {
        final a = r.alpha[i];
        if (a > 8 && a < 248) {
          semi++;
          final rr = r.rgba[j], gg = r.rgba[j + 1], bb = r.rgba[j + 2];
          if (bb - rr > 40 && bb - gg > 25) spill++;
        }
      }
      stdout.writeln('${e.key} ${r.width}x${r.height} ${ms}ms '
          'crop=${cw}x$ch semi=$semi blueSpill=$spill '
          '(${(100.0 * spill / math.max(1, semi)).toStringAsFixed(1)}%)');
      img.Image sheetOut = sheet;
      stdout.writeln('  sheet=${sheetOut.width}x${sheetOut.height} labels=$labels');
    }
  }, timeout: const Timeout(Duration(minutes: 50)));
}
