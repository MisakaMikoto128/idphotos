/// 木照 MuZhao — P0 歪斜复现实验台：用户两张源图全管线（YuNet + MODNet + compose）。
///
/// 运行（项目根目录）：
/// ```
/// flutter test lib/core/imaging/dev_roll_repro.dart
/// ```
///
/// 对 `C:/Users/liuyu/Pictures/1 (2).jpg`（室外自拍，2880×4982）与
/// `2.jpg`（蓝底证件照，1080×1415）逐阶段记录：
/// YuNet rollDeg / box / 头顶下巴，compose 的 straightenDeg 与裁剪框，
/// 成片 JPEG 与 alpha 掩膜落盘 `out/tmp/roll_repro/`。
/// 残差的外部测量（栏杆/肩线拟合）在 `out/tmp/roll_repro/step2_residual.py`。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

// flutter_test 是 dev_dependency；本文件是开发期自检，不进发布路径。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;
import 'package:muzhao/core/imaging/compose_engine.dart';
import 'package:muzhao/core/specs/photo_specs.dart';

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

class _FullEngine with MattingEngineMixin, ComposeEngineMixin {
  @override
  void dispose() {
    disposeMattingEngine();
  }
}

const Map<String, String> kSources = <String, String>{
  'p1': r'C:/Users/liuyu/Pictures/1 (2).jpg',
  'p2': r'C:/Users/liuyu/Pictures/2.jpg',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ort.debugModelDirectory = 'assets/models';
  _preloadHostOnnxRuntime();
  final engine = _FullEngine();
  final outDir = Directory('out/tmp/roll_repro');
  outDir.createSync(recursive: true);

  test('用户源图全管线逐阶段记录', () async {
    await engine.warmUp();
    final PhotoSpec spec = specCn1inch;

    for (final entry in kSources.entries) {
      final String tag = entry.key;
      final Uint8List bytes =
          File(entry.value).readAsBytesSync();

      final img.Image? decoded = img.decodeJpg(bytes);
      // ignore: avoid_print
      print('[$tag] srcSize=${decoded!.width}x${decoded.height}');

      final Stopwatch sw = Stopwatch()..start();
      final FaceInfo? face = await engine.detectFace(bytes);
      sw.stop();
      if (face == null) {
        // ignore: avoid_print
        print('[$tag] detectFace=null !!!!');
        continue;
      }
      // ignore: avoid_print
      print('[$tag] YuNet rollDeg=${face.rollDeg.toStringAsFixed(3)} '
          'conf=${face.confidence.toStringAsFixed(3)} '
          'box=(${face.box.left.toStringAsFixed(1)},'
          '${face.box.top.toStringAsFixed(1)},'
          '${face.box.width.toStringAsFixed(1)},'
          '${face.box.height.toStringAsFixed(1)}) '
          'headTopY=${face.headTopY.toStringAsFixed(1)} '
          'chinY=${face.chinY.toStringAsFixed(1)} '
          '(${sw.elapsedMilliseconds}ms)');

      final MattingResult matting = await engine.removeBackground(bytes);
      // alpha 掩膜落盘
      final img.Image alphaImg = img.Image.fromBytes(
        width: matting.width,
        height: matting.height,
        bytes: matting.alpha.buffer,
        numChannels: 1,
      );
      File('${outDir.path}/${tag}_alpha.png')
          .writeAsBytesSync(img.encodePng(alphaImg));

      // compose：蓝底与红底各出一张一寸
      for (final BackgroundStyle style in const [kBgBlue, kBgRed]) {
        final Candidate c = await engine.compose(
          matting: matting,
          spec: spec,
          style: style,
          face: face,
        );
        final String fn =
            '${outDir.path}/${tag}_${style.id}_cn1inch.jpg';
        File(fn).writeAsBytesSync(c.jpegBytes);
        // ignore: avoid_print
        print('[$tag] style=${style.id} -> $fn '
            '(${c.jpegBytes.length}B)');
      }
      final ComposeDiagnostics? d = engine.lastDiagnostics;
      // ignore: avoid_print
      print('[$tag] diag straightened=${d!.straightened} '
          'straightenDeg=${d.straightenDeg.toStringAsFixed(3)} '
          'crop=${d.cropRect} oob=${d.outOfBoundsFraction.toStringAsFixed(3)} '
          'shrunk=${d.shrunk} note=${d.note}');
    }
    await engine.disposeMattingEngine();
  }, timeout: const Timeout(Duration(minutes: 60)));
}
