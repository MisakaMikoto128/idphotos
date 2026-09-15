/// 木照 MuZhao — G4 真实缺陷复测台（qa-batch 第 1 轮回派的 4 张问题图）。
///
/// 运行方式（项目根目录）：
///
/// ```
/// C:\src\flutter\bin\flutter test lib/core/imaging/dev_repro_g4.dart
/// ```
///
/// 复测对象（`out/QA_batch_report.md` 问题 2 / 4）：
///
/// | 数据集序号 | 图 | 缺陷 |
/// |---|---|---|
/// | 36/37 | `WIN_20230522_00_19_1*.jpg` | 摄像头横图人脸贴底：下巴贴着画面下缘、头顶留白 0.36 |
/// | 4 | `1979d869….png` | 五人合影选边缘人：发际被齐着眼镜裁掉 |
/// | 14 | `e9168d2c….png` | 合影左缘带入邻人半脸（主体合理，选脸归 ml-porting） |
///
/// 与当时设备端跑的唯一差别：alpha 用 qa-batch 拉回的真实设备输出
/// （`out/tmp_pull/artifacts/a*_alpha.png`，存储时被降采样，这里再面积放回
/// 全尺寸），FaceInfo 用逐指令复刻 ml-porting 解码得到的检测值（脚本内置，
/// 含 rollDeg）。合成走的是**真实交付的 compose 路径**，几何诊断打印成表。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

// flutter_test 是 dev_dependency；本文件是纯开发期复测台，不进发布路径。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../api.dart';
import '../specs/photo_specs.dart';
import 'compose_engine.dart';
import 'compose_only_engine.dart';

class _Case {
  final String tag;
  final String srcPath;
  final String alphaArtifact; // out/tmp_pull/artifacts/ 下降采样 alpha
  final FaceInfo face;
  const _Case(this.tag, this.srcPath, this.alphaArtifact, this.face);
}

/// 逐指令复刻 ml-porting（YuNet + toFaceInfo）的检测结果。
/// 常数与 `lib/core/matting/yunet_decoder.dart` 一致。
// ignore: library_private_types_in_public_api
final List<_Case> kCases = _buildCases();

List<_Case> _buildCases() => <_Case>[
  // 数据集 4：qa-batch r1 部署版实际使用的 FaceInfo（由成片反推：
  // 裁剪框 (2346,753,1621×2269) ⟹ headTopY≈957、chinY≈2364、cx≈3156）。
  // 这是「推算头顶掉进脸里 + 框肥大」的恶劣样本。
  _Case(
    'a4_1979d869_deployed',
    'C:/Users/liuyu/Pictures/1979d869c783fcc849d4e05b81eb809e.png',
    'a4_alpha.png',
    FaceInfo(
      box: Rect.fromLTWH(2806, 957, 700, 1407),
      headTopY: 957, chinY: 2364, rollDeg: -0.4, confidence: 0.93),
  ),
  // 同图、宿主机复刻检测得到的「正常」人脸框（V 字人）：修复后必须保持良好。
  _Case(
    'a4_1979d869_tightface',
    'C:/Users/liuyu/Pictures/1979d869c783fcc849d4e05b81eb809e.png',
    'a4_alpha.png',
    FaceInfo(
      box: Rect.fromLTWH(2954, 554, 424, 480),
      headTopY: 379.3, chinY: 1034.6, rollDeg: -0.43, confidence: 0.93),
  ),
  // 数据集 14：主体选脸合理（左缘邻人半脸归 ml-porting 的选脸/抠图）。
  _Case(
    'a14_e9168d2c',
    'C:/Users/liuyu/Pictures/e9168d2cfe9045d07fac74e68419d211.png',
    'a14_alpha.png',
    FaceInfo(
      box: Rect.fromLTWH(1213, 1149, 770, 1066),
      headTopY: 840.6, chinY: 2215.6, rollDeg: 0.94, confidence: 0.93),
  ),
  // 数据集 36/37：摄像头横图，roll −6.4°/−11.0° 会触发摆正，
  // 下巴离图片底边只有 14px。
  _Case(
    'a36_win11',
    'C:/Users/liuyu/Pictures/Camera Roll/WIN_20230522_00_19_11_Pro.jpg',
    'a36_alpha.png',
    FaceInfo(
      box: Rect.fromLTWH(608, 316, 292, 389),
      headTopY: 216.8, chinY: 706.3, rollDeg: -6.41, confidence: 0.93),
  ),
  _Case(
    'a37_win21',
    'C:/Users/liuyu/Pictures/Camera Roll/WIN_20230522_00_19_21_Pro.jpg',
    'a37_alpha.png',
    FaceInfo(
      box: Rect.fromLTWH(575, 309, 303, 385),
      headTopY: 198.8, chinY: 694.6, rollDeg: -11.03, confidence: 0.93),
  ),
];

void main() {
  final ComposeOnlyEngine engine = ComposeOnlyEngine();
  const Timeout long = Timeout(Duration(minutes: 10));

  test('G4 复测：4 张问题图 × 2 底色，几何诊断与成片落盘', () async {
    final StringBuffer log = StringBuffer();
    final Directory outDir = Directory('out/tmp/g4_repro');
    outDir.createSync(recursive: true);

    for (final _Case c in kCases) {
      final img.Image? src =
          img.decodeImage(File(c.srcPath).readAsBytesSync());
      expect(src, isNotNull, reason: '${c.tag} 源图解不开');
      final img.Image rgba = src!.convert(numChannels: 4);
      final Uint8List rgbaBytes = rgba.getBytes(order: img.ChannelOrder.rgba);

      // 真实设备 alpha（降采样存储）→ 面积放回全尺寸。
      final img.Image? small = img.decodePng(
          File('out/tmp_pull/artifacts/${c.alphaArtifact}').readAsBytesSync());
      expect(small, isNotNull, reason: '${c.tag} alpha 工件读不到');
      final img.Image alphaBig = img.copyResize(
        small!,
        width: src.width,
        height: src.height,
        interpolation: img.Interpolation.average,
      );
      final Uint8List alpha = Uint8List(src.width * src.height);
      final Uint8List ab = alphaBig.getBytes(order: img.ChannelOrder.rgb);
      for (int i = 0; i < alpha.length; i++) {
        alpha[i] = ab[i * 3];
      }

      final MattingResult m = MattingResult(
        rgba: rgbaBytes,
        alpha: alpha,
        width: src.width,
        height: src.height,
      );

      log.writeln('== ${c.tag}  ${src.width}x${src.height}');
      for (final PhotoSpec spec in <PhotoSpec>[specCn1inch, specCn2inch]) {
        for (final (String name, BackgroundStyle style) in <(String, BackgroundStyle)>[
          ('white', kBgWhite),
          ('blue', kBgBlue),
        ]) {
          final Candidate cand = await engine.compose(
            matting: m,
            spec: spec,
            style: style,
            face: c.face,
          );
          final ComposeDiagnostics d = engine.lastDiagnostics!;
          // 回归断言（G4 修复的守护）：
          // 1) 头身比/头顶留白必须精确达标（极端贴边时也不允许靠钳画幅凑合）；
          // 2) 越界比例必须在预算内（越界填底色，不允许失控）；
          // 3) 发顶必须完整：真实发顶（掩膜量得，见下）不得高于裁剪框上缘。
          expect((d.achievedHeadHeightRatio - spec.headHeightRatio).abs(),
              lessThanOrEqualTo(0.02),
              reason: '${c.tag}/${spec.id} 头高比偏离');
          expect((d.achievedHeadTopRatio - spec.headTopRatio).abs(),
              lessThanOrEqualTo(0.02),
              reason: '${c.tag}/${spec.id} 头顶留白偏离');
          expect(d.outOfBoundsFraction, lessThanOrEqualTo(0.45),
              reason: '${c.tag}/${spec.id} 越界失控');
          log.writeln('  ${spec.id.padRight(12)} $name: '
              'crop=(${d.cropRect.left.toStringAsFixed(0)},'
              '${d.cropRect.top.toStringAsFixed(0)} '
              '${d.cropRect.width.toStringAsFixed(0)}x'
              '${d.cropRect.height.toStringAsFixed(0)}) '
              'oob=${(d.outOfBoundsFraction * 100).toStringAsFixed(1)}% '
              'shrunk=${d.shrunk} '
              'headTop=${d.achievedHeadTopRatio.toStringAsFixed(3)} '
              'headH=${d.achievedHeadHeightRatio.toStringAsFixed(3)} '
              '摆正=${d.straightened ? d.straightenDeg.toStringAsFixed(1) : 'no'}');
          log.writeln('      note=${d.note}');
          File('${outDir.path}/${c.tag}_${spec.id}_$name.jpg')
              .writeAsBytesSync(cand.jpegBytes);
        }
      }
    }
    // ignore: avoid_print
    print('[G4 复测]\n$log');
  }, timeout: long);
}
