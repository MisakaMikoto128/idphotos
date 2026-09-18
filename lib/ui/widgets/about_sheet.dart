/// "关于"浮层（PHASE6 W1）。
///
/// 一只真正的木抽屉（与规格抽屉同一交互语言：底部滑出、铜拉手、
/// `Curves.easeOutCubic` 320ms），抽屉里放着一张**带铜包角的纸质证书卡** ——
/// 1930 年代照相馆的抽屉里收着的就是这种装裱在卡纸上的执照/文凭。
///
/// 入口：区域 A 左上角"木照"铭牌**长按**。刻意做成不显眼的
/// 彩蛋式入口，避免在 A/B/C 三区里增加常驻控件（三段式布局红线），
/// 也不占用区域 C 本就紧张的 17% 空间。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/widgets.dart';

import '../theme/brass.dart';
import '../theme/paper_painter.dart';
import '../theme/surfaces.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../theme/wood_painter.dart';
import 'metal.dart';
import 'press_effect.dart';
import 'spec_drawer.dart' show DrawerPull;

/// 应用版本。与 `pubspec.yaml` 的 `version: 1.0.0+1` 保持一致。
///
/// 刻意**硬编码**而不是 `package_info`：pubspec 归主会话独占，引入
/// package_info_plus 需要新增依赖并改 pubspec（CLAUDE.md §7.5），
/// 对一个只在关于页显示一次的字符串不值当。升版本时改这里 + pubspec 两处。
const String kAppVersion = '1.0.0';

/// GitHub 仓库地址（占位，仓库尚未建立）。纯文本展示，不引入 url_launcher。
const String kRepoUrl = 'github.com/liuyuanlin/idphotos';

class AboutSheet extends StatelessWidget {
  final bool open;
  final VoidCallback onClose;

  const AboutSheet({
    super.key,
    required this.open,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !open,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          AnimatedOpacity(
            opacity: open ? 1 : 0,
            duration: Motion.area,
            curve: Motion.curve,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClose,
              child: const ColoredBox(color: Shade.scrim),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedSlide(
              offset: Offset(0, open ? 0 : 1),
              duration: Motion.area,
              curve: Motion.curve,
              child: _Drawer(onClose: onClose),
            ),
          ),
        ],
      ),
    );
  }
}

class _Drawer extends StatelessWidget {
  final VoidCallback onClose;

  const _Drawer({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final double bottom = MediaQuery.paddingOf(context).bottom;
    return WoodPanel(
      key: const Key('about_sheet'),
      spec: const WoodSpec(tone: WoodTone.light, seed: 87),
      grainOrigin: const Offset(0, 400),
      radius: const BorderRadius.vertical(top: Shape.panel),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 12 + (bottom > 0 ? 0 : 4)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Center(child: DrawerPull()),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Text('关于', style: Type.subtitle(T.creamText)),
                  const Spacer(),
                  PressSurface(
                    onTap: onClose,
                    sink: 1,
                    semanticLabel: '关闭关于页面',
                    builder: (BuildContext c, bool pressed) => SizedBox(
                      height: 30,
                      width: 62,
                      child: MetalPlate(
                        finish: MetalFinish.brass,
                        pressed: pressed,
                        seed: 3,
                        child: Center(
                          child: EngravedText(
                            '关闭',
                            style: Type.plate(T.inkBrown),
                            relief: T.brassHi,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const _CertificateCard(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 卡纸证书卡：纸质底 + 四角铜包角 + 铅印排版。
///
/// 注意不能直接用 [BrassCorners]（metal.dart）：它是一个**只有 Positioned
/// 子级的 Stack**，在抽屉这种"高度不定"的 Column 里拿不到有界约束，会抛
/// "Stack requires bounded constraints"。这里让纸质卡片作为 Stack 的
/// 非定位子级来撑开尺寸，包角用 Align 挂在四角 —— 与 [BrassCorners]
/// 同一套画笔，仅布局不同。
class _CertificateCard extends StatelessWidget {
  const _CertificateCard();

  static const double _cornerArm = 22;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        PaperSurface(
          seed: 33,
          edgeDarken: 1.0,
          radius: const BorderRadius.all(Radius.circular(3)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 吉祥物"木木"立绘头像（豆包生成，阶段 6）：给证书卡一张脸
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.asset(
                    'assets/images/mascot_about.jpg',
                    height: 132,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter, // 宽卡片下保住眼部以上
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '木照 MuZhao',
                  textAlign: TextAlign.center,
                  style: _titleStyle,
                ),
                const SizedBox(height: 2),
                Text(
                  '版本 v$kAppVersion',
                  textAlign: TextAlign.center,
                  style: Type.caption(T.inkBrown),
                ),
                const _Rule(),
                const _MetaRow(label: '作者', value: '刘沅林'),
                const _Rule(faint: true),
                Text('隐私承诺', style: _sectionStyle),
                const SizedBox(height: 6),
                const _PromiseRow('不收集任何数据'),
                const _PromiseRow('不传输任何数据'),
                const _PromiseRow('无网络权限'),
                const SizedBox(height: 10),
                const _OathStrip(),
                const SizedBox(height: 12),
                Text(
                  '开源许可：字体 Noto Serif SC（SIL OFL 1.1）',
                  style: _licenseStyle,
                ),
                const SizedBox(height: 3),
                Text(kRepoUrl, style: Type.caption(T.inkBrown)),
              ],
            ),
          ),
        ),
        _corner(Alignment.topLeft),
        _corner(Alignment.topRight),
        _corner(Alignment.bottomLeft),
        _corner(Alignment.bottomRight),
      ],
    );
  }

  Widget _corner(Alignment a) => Align(
        alignment: a,
        child: SizedBox(
          width: _cornerArm + 4,
          height: _cornerArm + 4,
          child: CustomPaint(
            painter: BrassCornerPainter(corner: a, arm: _cornerArm),
          ),
        ),
      );
}

/// 标题直接写在卡纸上，不用 [EngravedText] —— 纸上的铅印是平的，
/// 浮雕是金属件的细节。Type.title 的 letterSpacing 2 是给铜面刻字用的，
/// 纸面排版收回到 1。
TextStyle get _titleStyle =>
    Type.title(T.inkBrown).copyWith(letterSpacing: 1);

TextStyle get _sectionStyle => Type.plate(T.inkBrown);

TextStyle get _licenseStyle => Type.small(T.inkBrown);

/// 卡纸上的细分隔线。
class _Rule extends StatelessWidget {
  final bool faint;

  const _Rule({this.faint = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: SizedBox(
        height: 1,
        child: ColoredBox(
          color: T.paperEdge.withValues(alpha: faint ? 0.6 : 1.0),
        ),
      ),
    );
  }
}

/// 左标签右内容的铅印行。
class _MetaRow extends StatelessWidget {
  final String label;
  final String value;

  const _MetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.ideographic,
      children: <Widget>[
        Text(label, style: Type.small(T.inkBrown)),
        const Spacer(),
        Text(value, style: Type.bodyStrong(T.inkBrown)),
      ],
    );
  }
}

/// 一条隐私承诺：小铜钉 + 正文。
class _PromiseRow extends StatelessWidget {
  final String text;

  const _PromiseRow(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 16,
            height: 16,
            child: CustomPaint(
              painter: const _PinPainter(),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(child: Text(text, style: Type.body(T.inkBrown))),
        ],
      ),
    );
  }
}

/// 承诺条目前的铜钉。
class _PinPainter extends CustomPainter {
  const _PinPainter();

  @override
  void paint(Canvas canvas, Size size) {
    paintScrew(
      canvas,
      Offset(size.width / 2, size.height / 2),
      3.4,
      MetalFinish.brass,
      phase: 4,
    );
  }

  @override
  bool shouldRepaint(_PinPainter old) => false;
}

/// 核心承诺做成一条"骑缝章"式的横条：细双线框 + 正文加粗。
class _OathStrip extends StatelessWidget {
  const _OathStrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: T.paperEdge.withValues(alpha: 0.9)),
          bottom: BorderSide(color: T.paperEdge.withValues(alpha: 0.9)),
        ),
      ),
      child: Text(
        '本应用完全离线运行，照片永不离开你的设备',
        textAlign: TextAlign.center,
        // 13/700：主屏卡片内宽放不下 15px 的整句（会拆成两行还孤出一个字），
        // 降到字号阶的 13 并保留加粗，一行放下。
        style: Type.small(T.inkBrown).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}
