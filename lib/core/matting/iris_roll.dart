/// 瞳孔级眼线估计——阶段 6 P0「成片可见歪斜」的修复主力。
///
/// ## 为什么不能用 YuNet 的眼球关键点
///
/// `yunet_decoder.dart` 原先直接拿 YuNet 的双眼关键点连线当 `rollDeg`。
/// P0 复现（imaging 全管线 + 三方独立测量，见 `docs/PITFALLS.md` 与
/// `out/tmp/roll_repro/`）证明这两个点在真实照片上**落在上睑褶/眼睑上而
/// 不是瞳孔**，误差 3.7–6.7° 且**可反号**：
///
/// | 样本 | YuNet 眼线 | 独立真值 | 误差 |
/// |---|---|---|---|
/// | `1 (2).jpg` | +0.84° | −4.4° | 5.2°，方向相反 |
/// | `2.jpg`（本来就是竖直证件照） | −3.91° | −0.22° | 3.7° |
///
/// 第二行就是用户报的事故：一张好端端的竖直证件照被主动转歪 3.7°。
/// imaging 试过「眼线 + 嘴线 + 鼻轴」多线融合，实测三线同源于同一组眼睑
/// 关键点、强相关（104 组系列对照差 ±0.02°），是零和的——**换线救不了，
/// 必须换定位方案**。本文件就是那个方案：在 YuNet 眼点附近重新找**虹膜
/// 连通域**，用瞳孔连线定角。
///
/// ## 符号口径
///
/// 图像坐标系 x 向右、y 向下，与 `crop_geometry.dart` 的 `RotationPlan`
/// 约定一致（该文件头注：`rollDeg` 为正表示头向右倾）。取
/// **图像左侧那只眼 → 图像右侧那只眼** 的连线角
/// `atan2(Δy, Δx)`，与旧路径 `atan2(lm[3]−lm[1], lm[2]−lm[0])` 的取点顺序
/// 完全相同（`lm[0..1]` 是模型口径的"右眼"= 图像左眼）。符号已在
/// `native/bench/iris_roll_calib_test.dart` 上用注入已知旋转的系列实测标定。
///
/// ## 不可信就返回 unavailable
///
/// 契约（`api.dart` 的 [RollSource]）要求：测不出时给 `0.0` +
/// `RollSource.unavailable`，**绝不回退 YuNet 眼睑眼线**。"测不出"远好于
/// "测错"——测错会让整张照片反向歪，正是本次事故。
library;

import 'dart:math' as math;
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// 灰度平面
// ---------------------------------------------------------------------------

/// RGB（紧密 3 字节/像素）→ 工作分辨率灰度平面。Rec.601 整数权重。
Uint8List grayPlaneFromRgb(Uint8List rgb, int width, int height) {
  final n = width * height;
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final j = i * 3;
    out[i] = (77 * rgb[j] + 150 * rgb[j + 1] + 29 * rgb[j + 2]) >> 8;
  }
  return out;
}

/// RGBA（4 字节/像素）→ 灰度平面。与 [grayPlaneFromRgb] 逐位一致。
Uint8List grayPlaneFromRgba(Uint8List rgba, int width, int height) {
  final n = width * height;
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final j = i * 4;
    out[i] = (77 * rgba[j] + 150 * rgba[j + 1] + 29 * rgba[j + 2]) >> 8;
  }
  return out;
}

// ---------------------------------------------------------------------------
// 参数
// ---------------------------------------------------------------------------

/// 开窗半径 / 双眼距 —— **一组，不是定值**。
///
/// 要同时容下两件事：YuNet 眼点自身的位置误差（实测可偏到 ~0.25×眼距，
/// 且方向是**偏上**：落在上睑褶上）与虹膜半径（≈0.095×眼距，人眼虹膜
/// 直径约 0.19×瞳距）。0.30 是原来的唯一定值，0.30 在下限上留了
/// 0.105×眼距 的余量；再大就会把整条眉毛吞进来，尺寸门虽仍能挡住，
/// 但分位数阈值会被压暗。
///
/// **为什么是四个而不是一个**：分位数阈值是在窗口内统计的，所以窗口大小
/// 直接决定阈值，而窗口大小 = mul × ed、ed 又随输入像素抖动（同一张 c06
/// 在 d−3 量到 88.9、d−5 量到 84.9）。一个与答案无关的自由度决定答案 =
/// 判决不稳。实测代价：c06_d−3 的右眼在 r=27 时一个候选都没有、整只眼
/// 判失败，而 c06_d−5 在 r=25 时 p4 档稳稳拿到 d=15.0 n=86。
/// 扫描见 [kPupilWindowRadiusMultipliers]。
const double kPupilWindowRadiusInEyeDist = 0.30;

/// 开窗半径的扫描档（× 双眼距）。见 [kPupilWindowRadiusInEyeDist]。
///
/// 下限 0.20 仍能容下"眼点偏 0.093×眼距（真图实测上界）+ 虹膜半径
/// 0.095×眼距"；上限 0.36 略超原来的 0.30，用来在眼点偏得多的图上兜底。
/// 四档各收一遍候选后一起竞争，几何门一道不放松，因此不新增误检面，
/// 只是不再让"窗口该开多大"决定答案。耗时 ×3.6（中位 1.7ms → 6ms）。
const List<double> kPupilWindowRadiusMultipliers = <double>[0.20, 0.25, 0.30, 0.36];

/// 连通域最长边 / 双眼距 的合法区间。
///
/// 人眼虹膜直径 ≈ 0.19×瞳距（生物力学事实，且与瞳距无关地近似恒定），
/// 被上眼睑切掉一点后实测落在这个区间里。区间不是拍脑袋来的——
/// `iris_roll_calib_test.dart` 在 20 张真实人像 + 门禁 78 张旋转夹具上
/// 量到的**合法**虹膜直径是 0.148–0.284×眼距（低端 c08_d−3 的右眼，
/// 高端 g08 的左眼）。取 [0.11, 0.32] 两侧各留 ~35% / ~13% 余量。
///
/// 这条门是"**测得数太小 ⇒ 根本没找到虹膜**"的主力，实测挡下两类误检：
///   · c11（5 人合影，主体眼只占很小一块）——检出的 0.049/0.077×眼距
///     其实是噪点，真值 −0.11° 而它给出 −4.45°，是本修复最危险的失败模式；
///   · c06_d−3 的右眼 0.090×眼距——那是眉梢不是虹膜（给出 −15.4° vs −4.7°）。
/// 反过来，眉毛/整只眼眶这类"太大"的由上限 0.32 与 aspect 门一起挡。
const double kPupilMinSizeInEyeDist = 0.11;
const double kPupilMaxSizeInEyeDist = 0.32;

/// 连通域 短边/长边 的下限。
///
/// **不要按正圆来卡**：虹膜被上下眼睑切掉后是个扁圆，实测 aspect 常落在
/// 0.6–0.7；上一轮按正圆卡就是在这里踩的坑。0.50 只排除"横长条"（眼镜
/// 上框、眉毛、瞼板腺线）。
const double kPupilMinAspect = 0.50;

/// 圆度 = 连通域面积 / 其外接矩形的内接椭圆面积。实心椭圆 = 1.0。
///
/// 镜片反光会在虹膜里挖洞、睫毛会粘边，所以不能要求太满；0.62 是原型在
/// 真实照片上跑通的取值。
///
/// **这条门坐在一段连续分布上，不是一个分离面——不要指望靠挪它提覆盖。**
/// 实测（123 张：门禁 78 夹具 + 12 锚点原图 + 语料 33）被它挡下的域有 889 个，
/// 其中 106 个落在 [0.60,0.62)、215 个落在 [0.55,0.60)；同时**当前胜出**的域
/// 里有 8 个落在 [0.62,0.65)。即两侧都没有空档，阈值切在人群中间。
/// 试过整体放到 0.55：`c06_d−3` 是修好了，但 `c08_d−3` 的右眼立刻被一个
/// `d=36 circ=0.55` 的合并域占掉（它与真虹膜 `d=22 circ=0.63` 在同一 dedup 组，
/// 先验距离 0.24 vs 0.25，一线之差），误差 0.12° → 1.01°，全库最差误差
/// 0.67° → 1.01°。**已回退**，别再试。
///
/// 个别真虹膜落在门下的（c06_d−3 右眼 `circ=0.58`）改由**双眼互相佐证**那条路
/// 兜（见 [kPupilCorroborateMinCircularity]），只对那一只眼放宽，不动这条门。
const double kPupilMinCircularity = 0.62;

/// 连通域最小像素数（原图像素，未取样时即 1:1）。
const int kPupilMinAreaPx = 12;

/// 双眼距小于这个像素数就不做瞳孔估计。
///
/// 虹膜直径 ≈ 0.19×眼距，要稳定成像至少得有 ~4px 直径 → 眼距 ≳ 21px。
/// 卡片头像之类的极小脸走这条路直接判 unavailable（诚实失败）。
const double kPupilMinEyeDistPx = 22.0;

/// 双眼**等面积直径**之比的上限，超过即判"一只眼找错了"。
///
/// 等面积直径 = `2·√(面积/π)`，与该域同面积的圆的直径（见 [estimatePupilRoll]
/// 的 ratio 一段）。
///
/// 实测（`native/bench/iris_roll_calib_test.dart` D 段，门禁 78 张旋转夹具
/// + 语料 20 张）真图双眼直径比最大 1.23（g07，左眼虹膜与睫毛粘连），
/// 而 c06_d−3 的误检（左眼虹膜 d=16 / 右眼眉梢 d=8）是 2.0。
/// 1.6 在真图上留 30% 余量，在误检上留 25% 拒绝余量。
const double kPupilMaxDiameterRatio = 1.6;

/// 第二趟（**双眼互相佐证**）的三个准入上限，只在某只眼**一个候选都没有**时启用。
///
/// 单眼的几何门是"这个域像不像虹膜"的**孤立**判断；某只眼全被否掉时，
/// 还有一份独立信息没用上：**另一只眼量到的虹膜有多大、多扁**。同一个人的
/// 两只眼，虹膜尺寸与可见形状高度接近，所以另一只眼的读数可以给这只眼当
/// 参照物——只接受与它量级相符的域，圆度门才允许放到
/// [kPupilCorroborateMinCircularity]。
///
/// **这不是把圆度门整体放松**：正常路径仍用 [kPupilMinCircularity] 的严格门，
/// 这里放宽的候选还必须同时满足直径比 ≤ [kPupilCorroborateMaxDiameterRatio]
/// 且 aspect 比 ≤ [kPupilCorroborateMaxAspectRatio]——两条都是**独立于圆度**
/// 的证据。实测（123 张）只有 2 只眼会走到这条路径（都是 c06 的右眼，
/// d−3 与 d+3），所以它对全库其余样本的影响为零。
///
/// 实测 c06_d−3 右眼：真虹膜 `d=15 asp=0.67 circ=0.58`，被 0.62 的圆度门挡下
/// （差 0.04），而另一只眼 `d=16 asp=0.69 circ=0.77` 是干净的。佐证放行后
/// 瞳孔连线给 −4.71°，独立真值 −4.73°。
const double kPupilCorroborateMaxDiameterRatio = 1.30;
const double kPupilCorroborateMaxAspectRatio = 1.40;
const double kPupilCorroborateMinCircularity = 0.45;

/// 检出点与 YuNet 种子的距离上限 / 双眼距。
///
/// 依据：YuNet 眼点偏移的已知上界 ~0.25×眼距（P0 实测）+ 虹膜半径
/// ~0.095×眼距 ≈ 0.345。取 0.33（略紧于该上界，因为它是**候选过滤器**
/// 而非硬否决——窗里还有别的候选时会让位给更靠种子的那个）。
/// 实测真图 20 张的偏移全部 ≤0.093×眼距（3.5× 余量），
/// 而 c06_d−3 的右眼误检在 0.408×眼距 —— 干净分离。
const double kPupilMaxSeedOffsetInEyeDist = 0.33;

/// 估计角绝对值上限，超过即判误检（正常证件照不可能到这个量级）。
const double kPupilMaxRollDeg = 45.0;

/// 窗内多阈值分位数。虹膜约占窗口面积的 8%，这一串从"只取最暗的瞳孔"
/// 到"连虹膜外环一起"扫一遍；眼镜反光/睫毛粘边会让某几档失败，其余档仍能给出候选。
///
/// 试过并**已否决**的扩展：加 [16,20,25] 高档（覆盖 85%→78%，高档把眉毛
/// 吞进来触发争鸣否决），以及"比 5×5 邻域均值暗 N 灰阶"的局部对比度判据
/// （候选全被尺寸门挡下，最差误差一位数字都没变，纯增 8% 耗时）。
/// 详见 `docs/PITFALLS.md`。
const List<double> kPupilPercentiles = <double>[2, 4, 6, 9, 12];

/// 同一只眼跨分位数的候选去重距离 / 双眼距。
const double kPupilDedupInEyeDist = 0.12;

/// 判"两家争鸣"的分数门槛：**竞争者**（与首选隔开去重距离之外的那些）
/// 里只要有一个得分达到首选的这个比例，就认为窗内有两个像虹膜的东西、
/// 谁是虹膜无法判定，整只眼判失败。
///
/// 门槛不能设成"只要存在第二个候选就失败"——实测（`iris_roll_debug_test`）
/// 眼周永远有零星暗斑（泪阜阴影、痣、眉梢），面积 13–57px 得分只有首选的
/// 3–16%，一律否决会把 p2/g01、g03、g07、报名照片全判成 unavailable。
/// 取 0.5 是"势均力敌才叫争"：宁可多判失败（不转），不可赌错（转反）。
const double kPupilRivalScoreRatio = 0.5;

/// 允许一个"竞争者"参与争鸣的**额外**种子距离（× 眼距）。
///
/// 争鸣门只看分数是错的：眉毛离眼点很远，但面积大、得分能到真虹膜的 50%
/// 以上，于是它能把**正确的**答案否决掉。实测 c08_d−3 的右眼就死在这里——
/// 真虹膜在 (838,451)（离种子 5.6px=0.038×眼距，用它算得 −10.65° vs 真值
/// −11.01°，误差 0.36°），而眉毛在 (835,402)（离种子 44px=0.296×眼距）
/// 得分 86 / 150 = 57% > 0.5，触发歧义 → 整只眼放弃。
///
/// 所以只有"跟首选一样像虹膜地贴近种子"的候选才有资格否决：
/// 实测真图虹膜中心离 YuNet 种子 ≤0.093×眼距（20 张），眉毛那类假候选在
/// 0.296×眼距，0.15 在两侧都留了余量。**这不是放松准入**——候选仍要过全部
/// 几何门，只是不再让一个明显不是虹膜的东西行使否决权。
const double kPupilRivalSeedSlackInEyeDist = 0.15;

/// 虹膜直径的生物常数先验（直径 / 双眼距）。
///
/// 人眼虹膜横径约 11–12mm，成人瞳距约 60–65mm，比值 ≈0.19，且**与个体、
/// 性别、年龄近似无关**——这是验光/生物识别里可以直接用的硬常数。
/// 本文件只在**同一个 dedup 组内**用它挑代表（见 [_findPupil] 的 reps），
/// 不用它做全局重排，避免惩罚真实的大虹膜（实测真图合法上限 0.284×眼距）。
const double kPupilIrisDiameterPrior = 0.19;

/// 瞳孔眼线与 YuNet 眼点的连线角之差的上限（度），超过即判误检。
///
/// **这不是回退**——YuNet 的值只用来否决，永远不出现在输出里。YuNet 眼点
/// 的角度误差实测 ≤7°（P0 复现的四例），把它当宽松的合理性边界（20°）足够
/// 安全：只有瞳孔结果偏到 13° 以上才会被拒，而那已经比事故量级还大。
/// 真正的倾斜会同时改变两条线，差值不变，所以本门不会误杀正常倾斜照片。
const double kPupilMaxSeedDisagreementDeg = 20.0;

/// 采样窗口的边长上限（像素）。超过则按整数步长抽样，控制单张耗时。
const int kPupilMaxWindowEdge = 288;

/// 二维欧氏距离。`dart:math` 没有 `hypot`，且这里的两点尺度同量级，
/// 直接开方不会溢出。
double _hypot(double dx, double dy) => math.sqrt(dx * dx + dy * dy);

/// 候选（直径 [diameter]、[aspect]）是否与另一只眼的读数 [ref] **量级相符**。
/// 第二趟的准入条件，见 [kPupilCorroborateMaxDiameterRatio]。
bool _corroboratesBy(PupilPoint ref, double diameter, double aspect) {
  final double dr = diameter > ref.diameterPx
      ? diameter / ref.diameterPx
      : ref.diameterPx / diameter;
  final double ar =
      aspect > ref.aspect ? aspect / ref.aspect : ref.aspect / aspect;
  return dr <= kPupilCorroborateMaxDiameterRatio &&
      ar <= kPupilCorroborateMaxAspectRatio;
}

// ---------------------------------------------------------------------------
// 结果
// ---------------------------------------------------------------------------

/// 一只眼的虹膜定位结果。[x]/[y] 为工作分辨率坐标下的连通域质心。
class PupilPoint {
  const PupilPoint({
    required this.x,
    required this.y,
    required this.diameterPx,
    required this.areaPx,
    required this.circularity,
    required this.aspect,
    required this.percentile,
  });

  final double x;
  final double y;

  /// 外接矩形最长边（原图像素）。
  final double diameterPx;

  final int areaPx;
  final double circularity;
  final double aspect;

  /// 这一个候选是在哪一档分位数上被检出的（排查用）。
  final double percentile;

  @override
  String toString() => 'Pupil(${x.toStringAsFixed(1)},'
      '${y.toStringAsFixed(1)} d=${diameterPx.toStringAsFixed(1)} '
      'n=$areaPx circ=${circularity.toStringAsFixed(2)} '
      'asp=${aspect.toStringAsFixed(2)} p$percentile)';
}

/// 瞳孔眼线估计。
///
/// [available] 为 false 时 [rollDeg] 恒为 0.0，调用方必须据此填
/// `RollSource.unavailable`，**不得回退任何眼睑关键点结果**。
class PupilRoll {
  const PupilRoll.estimated({
    required this.rollDeg,
    required this.left,
    required this.right,
    required this.eyeDistPx,
  })  : available = true,
        reason = 'ok';

  const PupilRoll.unavailable(this.reason)
      : available = false,
        rollDeg = 0.0,
        left = null,
        right = null,
        eyeDistPx = 0.0;

  final bool available;

  /// **待施加的摆正角**（度），与 `FaceInfo.rollDeg` 同口径。
  final double rollDeg;

  /// 图像左侧那只眼（x 较小者）。
  final PupilPoint? left;

  /// 图像右侧那只眼。
  final PupilPoint? right;

  final double eyeDistPx;

  /// 成功恒为 `'ok'`；失败时是给排查看的一句原因。
  final String reason;

  @override
  String toString() => available
      ? 'PupilRoll(${rollDeg.toStringAsFixed(2)}°, '
          'L=$left R=$right ed=${eyeDistPx.toStringAsFixed(0)})'
      : 'PupilRoll(unavailable: $reason)';
}

// ---------------------------------------------------------------------------
// 估计
// ---------------------------------------------------------------------------

/// 用 YuNet 的两个眼点作种子，在 [gray]（工作分辨率灰度平面）里重新定位
/// 双眼虹膜，返回瞳孔连线给出的待施加摆正角。
///
/// 两个种子点谁在左谁在右不做假设，本函数内部按 x 排序归一。
///
/// [trace] 非 null 时把每只眼窗内的候选统计与拒绝原因逐行追加进去——
/// 只给 dev 探针（`native/bench/iris_roll_debug_test.dart`）调参用，
/// 生产调用一律传 null（只多一次 null 判断）。
PupilRoll estimatePupilRoll({
  required Uint8List gray,
  required int width,
  required int height,
  required double eyeAx,
  required double eyeAy,
  required double eyeBx,
  required double eyeBy,
  List<String>? trace,
}) {
  if (gray.length < width * height) {
    return const PupilRoll.unavailable('gray plane too short');
  }
  var lx = eyeAx, ly = eyeAy, rx = eyeBx, ry = eyeBy;
  if (!lx.isFinite || !ly.isFinite || !rx.isFinite || !ry.isFinite) {
    return const PupilRoll.unavailable('non-finite eye seed');
  }
  if (rx < lx) {
    final double t = lx;
    lx = rx;
    rx = t;
    final double t2 = ly;
    ly = ry;
    ry = t2;
  }
  final double ed = _hypot(rx - lx, ry - ly);
  if (ed < kPupilMinEyeDistPx) {
    return PupilRoll.unavailable(
        'eye distance ${ed.toStringAsFixed(1)}px < $kPupilMinEyeDistPx');
  }
  trace?.add('ed=${ed.toStringAsFixed(1)} '
      'Lseed=(${lx.toStringAsFixed(1)},${ly.toStringAsFixed(1)}) '
      'Rseed=(${rx.toStringAsFixed(1)},${ry.toStringAsFixed(1)})');

  PupilPoint? l = _findPupil(gray, width, height, lx, ly, ed, 'L', trace);
  PupilPoint? rr = _findPupil(gray, width, height, rx, ry, ed, 'R', trace);
  // 第二趟：某只眼一个候选都没收上来时，用**另一只眼的读数**当参照再找一次
  // （只放宽圆度门，且候选必须与参照量级相符）。见 kPupilCorroborateMinCircularity。
  if (l == null && rr != null) {
    l = _findPupil(gray, width, height, lx, ly, ed, 'L*', trace,
        corroborate: rr);
  } else if (rr == null && l != null) {
    rr = _findPupil(gray, width, height, rx, ry, ed, 'R*', trace,
        corroborate: l);
  }
  if (l == null) {
    return const PupilRoll.unavailable('no iris blob at left eye seed');
  }
  if (rr == null) {
    return const PupilRoll.unavailable('no iris blob at right eye seed');
  }

  // 双眼一致性：同一个人两只眼的虹膜**大小**相同。差太多说明其中一只找到了
  // 别的东西（眉毛、镜框、卧蚕阴影），此时宁可不给角。
  //
  // 比的是**等面积直径**（`2·√(面积/π)`，与该域同面积的圆的直径），不是外接
  // 矩形的长边。长边不是抗形状的尺寸：上睑阴影/睫毛沿睑缘**横向**并进来时，
  // 域的宽度会被拉长而面积几乎不变，长边于是高报（实测 c08_d−10 左眼 d=39、
  // 同域等面积直径只有 25.1）。而"两只眼虹膜一样大"本来就是**面积**意义上的
  // 陈述，等面积直径才是它的直接对应物。
  //
  // 阈值 1.6 不动。实测（`native/bench/iris_roll_debug_test.dart`，门禁 78 夹具
  // + 12 锚点原图 + 语料 33 张 = 123 张）这条门**全库只触发 1 次**，就是
  // c08_d−10：长边比 1.86 判失败，等面积直径比 1.44 通过。因为只触发 1 次，
  // 换度量对本轮其余样本的影响是**零**——这不是放松，是换一把量对东西的尺。
  final double dEqL = 2 * math.sqrt(l.areaPx / math.pi);
  final double dEqR = 2 * math.sqrt(rr.areaPx / math.pi);
  final double ratio = dEqL > dEqR ? dEqL / dEqR : dEqR / dEqL;
  if (ratio > kPupilMaxDiameterRatio) {
    trace?.add('ratioGate eqRatio=${ratio.toStringAsFixed(2)} '
        'dEqL=${dEqL.toStringAsFixed(1)} dEqR=${dEqR.toStringAsFixed(1)} '
        'L=$l R=$rr');
    return PupilRoll.unavailable(
        'iris size mismatch eqL=${dEqL.toStringAsFixed(1)} '
        'eqR=${dEqR.toStringAsFixed(1)} (dEq ratio '
        '${ratio.toStringAsFixed(2)} > $kPupilMaxDiameterRatio)');
  }

  final double roll = math.atan2(rr.y - l.y, rr.x - l.x) * 180.0 / math.pi;
  if (!roll.isFinite || roll.abs() > kPupilMaxRollDeg) {
    return PupilRoll.unavailable(
        'implausible roll ${roll.toStringAsFixed(2)}°');
  }
  // 与种子连线的一致性：只否决，不采用（见 kPupilMaxSeedDisagreementDeg）。
  final double seedLine = math.atan2(ry - ly, rx - lx) * 180.0 / math.pi;
  if ((roll - seedLine).abs() > kPupilMaxSeedDisagreementDeg) {
    return PupilRoll.unavailable('pupil ${roll.toStringAsFixed(1)}° vs '
        'seed line ${seedLine.toStringAsFixed(1)}° disagree');
  }
  return PupilRoll.estimated(
    rollDeg: roll,
    left: l,
    right: rr,
    eyeDistPx: ed,
  );
}

/// 在 [sx],[sy] 周围找虹膜连通域。找不到返回 null。
///
/// **窗口半径是扫描量，不是一个定值**——这一点是实测逼出来的，别改回去。
/// [ed] 是 YuNet 给的双眼距，它自己就随输入像素变化：同一张 c06 在 d−3 量到
/// ed=88.9、d−5 量到 84.9。窗口半径 r=0.30·ed 跟着变（27px vs 25px），
/// **而分位数阈值是在窗口内统计的**，窗口一变、直方图就变、同一颗虹膜可能
/// 从"最暗的 4%"掉出去。实测后果：c06_d−5 右眼在 r=25 的 p4 档拿到
/// d=15.0 n=86 的好候选，c06_d−3 右眼在 r=27 的 p4 档**一个候选都没有**，
/// 于是整只眼判失败——同一张图、相隔 2°，一个残余 0.020°、另一个直接放弃。
///
/// 所以正确的做法是把 r 当** nuisance parameter 边际化**：几个半径各收一遍
/// 候选，一起竞争。候选的几何门（尺寸/圆度/aspect/种子偏移）一道都不放松，
/// 因此这不引入新的误检面，只是不再让"窗口该开多大"这个与答案无关的自由度
/// 决定答案。代价是耗时 ×3.6，实测中位 1.7ms → 6ms 量级，可忽略。
PupilPoint? _findPupil(Uint8List gray, int width, int height, double sx,
    double sy, double ed, String tag, List<String>? trace,
    {PupilPoint? corroborate}) {
  final cands = <_Blob>[];
  // 拒绝计数（只在 [trace] 非 null 时用于报告，生产路径上是一次加法）。
  var nBlob = 0, rejSize = 0, rejAspect = 0, rejCirc = 0, rejFar = 0;
  var minAreaSeen = 0;
  var minSizeSeen = 0.0, maxSizeSeen = 0.0;

  for (final double mul in kPupilWindowRadiusMultipliers) {
    final int r = math.max(6, (mul * ed).round());
    final int x0 = math.max(0, sx.floor() - r);
    final int x1 = math.min(width, sx.ceil() + r + 1);
    final int y0 = math.max(0, sy.floor() - r);
    final int y1 = math.min(height, sy.ceil() + r + 1);
    final int spanX = x1 - x0;
    final int spanY = y1 - y0;
    if (spanX < 4 || spanY < 4) continue;

    // 大窗按整数步长抽样，把单张耗时钉在常数上；坐标最后乘回步长，
    // 精度损失 ≤ 1px（眼距数百像素时对角度的影响 < 0.2°）。
    final int edge = math.max(spanX, spanY);
    final int step = edge <= kPupilMaxWindowEdge
        ? 1
        : (edge / kPupilMaxWindowEdge).ceil();
    final int sw = (spanX + step - 1) ~/ step;
    final int sh = (spanY + step - 1) ~/ step;
    final int total = sw * sh;

    // 抽样后的窗口灰度 + 直方图（灰度为 0..255 整数，直方图给出精确分位数，
    // 比排序 total 个元素便宜一个量级）。
    final win = Uint8List(total);
    final hist = Int32List(256);
    var k = 0;
    for (var iy = 0; iy < sh; iy++) {
      final srcRow = y0 + iy * step;
      final base = srcRow * width;
      for (var ix = 0; ix < sw; ix++, k++) {
        final v = gray[base + x0 + ix * step];
        win[k] = v;
        hist[v]++;
      }
    }


    final double pxPerSample = step.toDouble();
    final double maxSize = kPupilMaxSizeInEyeDist * ed; // 原图像素
    final double minSize = kPupilMinSizeInEyeDist * ed;
    final int minArea =
        math.max(4, (kPupilMinAreaPx / (pxPerSample * pxPerSample)).floor());

    final visited = Uint8List(total);
    final stack = Int32List(total);
    minAreaSeen = minArea;
    minSizeSeen = minSize;
    maxSizeSeen = maxSize;

    /// 在"暗像素"掩码上跑一遍 8 邻接连通域，收候选。
    /// [label] 只用于 trace（分位数档为正，局部对比度档为负）。
    void scan(bool Function(int p) isDark, double label) {
      visited.fillRange(0, total, 0);
      for (var seed = 0; seed < total; seed++) {
        if (visited[seed] != 0) continue;
        visited[seed] = 1;
        if (!isDark(seed)) continue;
        var sp = 0;
        stack[sp++] = seed;
        var area = 0;
        var sumX = 0.0, sumY = 0.0;
        var minX = sw, maxX = -1, minY = sh, maxY = -1;
        while (sp > 0) {
          final q = stack[--sp];
          final qx = q % sw;
          final qy = q ~/ sw;
          area++;
          sumX += qx;
          sumY += qy;
          if (qx < minX) minX = qx;
          if (qx > maxX) maxX = qx;
          if (qy < minY) minY = qy;
          if (qy > maxY) maxY = qy;
          final int yA = qy > 0 ? qy - 1 : 0;
          final int yB = qy < sh - 1 ? qy + 1 : sh - 1;
          for (var ny = yA; ny <= yB; ny++) {
            final int rowBase = ny * sw;
            final int xA = qx > 0 ? qx - 1 : 0;
            final int xB = qx < sw - 1 ? qx + 1 : sw - 1;
            for (var nx = xA; nx <= xB; nx++) {
              final int p = rowBase + nx;
              if (visited[p] != 0) continue;
              visited[p] = 1;
              if (!isDark(p)) continue;
              stack[sp++] = p;
            }
          }
        }
        if (area < minArea) continue;
        nBlob++;
        final double bw = (maxX - minX + 1) * pxPerSample;
        final double bh = (maxY - minY + 1) * pxPerSample;
        final double longSide = math.max(bw, bh);
        final double shortSide = math.min(bw, bh);
        if (longSide > maxSize || longSide < minSize) {
          rejSize++;
          trace?.add('  $tag $label rejSize d=${longSide.toStringAsFixed(1)} '
              'n=${(area * pxPerSample * pxPerSample).round()} '
              'asp=${(shortSide / longSide).toStringAsFixed(2)} '
              'circ=${(area * pxPerSample * pxPerSample / (bw * bh * math.pi / 4)).toStringAsFixed(2)} '
              'seedOff=${(_hypot(x0 + (sumX / area) * pxPerSample - sx, y0 + (sumY / area) * pxPerSample - sy) / ed).toStringAsFixed(3)} '
              'xy=(${(x0 + (sumX / area) * pxPerSample).toStringAsFixed(0)},'
              '${(y0 + (sumY / area) * pxPerSample).toStringAsFixed(0)})');
          continue;
        }
        final double aspect = shortSide / longSide;
        if (aspect < kPupilMinAspect) {
          rejAspect++;
          trace?.add('  $tag $label rejAspect d=${longSide.toStringAsFixed(1)} '
              'asp=${aspect.toStringAsFixed(2)} '
              'xy=(${(x0 + (sumX / area) * pxPerSample).toStringAsFixed(0)},'
              '${(y0 + (sumY / area) * pxPerSample).toStringAsFixed(0)})');
          continue;
        }
        final double cx0 = x0 + (sumX / area) * pxPerSample + (step - 1) / 2.0;
        final double cy0 = y0 + (sumY / area) * pxPerSample + (step - 1) / 2.0;
        // 候选过滤器（不是硬否决）：离种子太远的让位给更靠种子的候选。
        if (_hypot(cx0 - sx, cy0 - sy) >
            kPupilMaxSeedOffsetInEyeDist * ed) {
          rejFar++;
          trace?.add('  $tag $label rejFar d=${longSide.toStringAsFixed(1)} '
              'seedOff=${(_hypot(cx0 - sx, cy0 - sy) / ed).toStringAsFixed(3)} '
              'xy=(${cx0.toStringAsFixed(0)},${cy0.toStringAsFixed(0)})');
          continue;
        }
        // 圆度用**原图像素**面积算，抽样不改变量纲。
        final double areaPx = area * pxPerSample * pxPerSample;
        final double circ = areaPx / (bw * bh * math.pi / 4);
        if (circ < kPupilMinCircularity) {
          // 第二趟：另一只眼成功过，且这一个候选在**直径与 aspect 上**都与它
          // 相符 —— 那它是一条独立的、非形状的证据支持的虹膜，圆度门让路。
          // 见 kPupilCorroborateMinCircularity。
          if (corroborate == null ||
              circ < kPupilCorroborateMinCircularity ||
              !_corroboratesBy(corroborate, longSide, aspect)) {
            rejCirc++;
            trace?.add('  $tag $label rejCirc d=${longSide.toStringAsFixed(1)} '
                'asp=${aspect.toStringAsFixed(2)} '
                'circ=${circ.toStringAsFixed(2)} '
                'seedOff=${(_hypot(cx0 - sx, cy0 - sy) / ed).toStringAsFixed(3)} '
                'xy=(${cx0.toStringAsFixed(0)},${cy0.toStringAsFixed(0)})');
            continue;
          }
          trace?.add('  $tag $label CORROBORATED d=${longSide.toStringAsFixed(1)} '
              'asp=${aspect.toStringAsFixed(2)} circ=${circ.toStringAsFixed(2)} '
              'xy=(${cx0.toStringAsFixed(0)},${cy0.toStringAsFixed(0)}) '
              'ref=$corroborate');
        }
        final double cx = cx0;
        final double cy = cy0;
        cands.add(_Blob(
          x: cx,
          y: cy,
          diameter: longSide,
          areaPx: areaPx,
          circularity: circ,
          aspect: aspect,
          percentile: label,
          // 又大又圆者优先；比面积更抗"整块眼窝被当成一个域"。
          score: areaPx * circ * circ,
        ));
        trace?.add('  $tag $label r=$r win=${sw}x$sh '
            'cand d=${longSide.toStringAsFixed(1)} n=${areaPx.round()} '
            'circ=${circ.toStringAsFixed(2)} asp=${aspect.toStringAsFixed(2)} '
            'xy=(${cx.toStringAsFixed(0)},${cy.toStringAsFixed(0)})');
      }
    }

    for (final double pct in kPupilPercentiles) {
      final int thr = _percentile(hist, total, pct);
      scan((int p) => win[p] <= thr, pct);
    }


  }

  if (cands.isEmpty) {
    trace?.add('  $tag REJECT all (blobs=$nBlob size=$rejSize '
        'aspect=$rejAspect far=$rejFar circ=$rejCirc '
        'minArea=$minAreaSeen sizeGate=${minSizeSeen.toStringAsFixed(1)}..'
        '${maxSizeSeen.toStringAsFixed(1)}px)');
    return null;
  }

  cands.sort((a, b) => b.score.compareTo(a.score));
  final double dedup = kPupilDedupInEyeDist * ed;
  final double prior = kPupilIrisDiameterPrior * ed;

  // 同一颗虹膜在不同半径档下会被量成**一组嵌套的域**：窗口开大就把上睑阴影
  // 连进来，测得偏大。它们在 dedup 距离内，属于同一个物体，不该按"谁面积大
  // 谁赢"挑——那会系统性偏向"虹膜+眼睑阴影"的合并域（实测 c08_d−3 左眼：
  // r=30 给 d=31、r=37 给 d=39，后者面积大所以赢，于是双眼直径比
  // 39/22=1.77 撞上 1.6 的门，把一只本来找对的眼睛判失败）。
  // 组内改挑**直径最接近生物常数 0.19×眼距**的那个；跨组仍按分数排，
  // 所以不同物体之间的竞争规则没变。
  final List<_Blob> reps = <_Blob>[];
  for (final _Blob c in cands) {
    var host = -1;
    for (var i = 0; i < reps.length; i++) {
      if (_hypot(c.x - reps[i].x, c.y - reps[i].y) <= dedup) {
        host = i;
        break;
      }
    }
    if (host < 0) {
      reps.add(c);
    } else if ((math.log(c.diameter / prior)).abs() <
        (math.log(reps[host].diameter / prior)).abs()) {
      reps[host] = c;
    }
  }
  reps.sort((a, b) => b.score.compareTo(a.score));
  trace?.add('  $tag reps=${reps.length} (dedup=${dedup.toStringAsFixed(1)} '
      'prior=${prior.toStringAsFixed(1)}) '
      '[${reps.take(8).join(' | ')}]');

  final _Blob kind = reps.first;
  final double rivalFloor = kind.score * kPupilRivalScoreRatio;
  final double kindSeedDist = _hypot(kind.x - sx, kind.y - sy);
  final double rivalSeedLimit =
      kindSeedDist + kPupilRivalSeedSlackInEyeDist * ed;
  for (final c in reps.skip(1)) {
    // 已按分数降序排过，剩下的只会更小。
    if (c.score < rivalFloor) break;
    if (_hypot(c.x - kind.x, c.y - kind.y) <= dedup) continue;
    // 离种子远得多的"竞争者"不参与争鸣——见 kPupilRivalSeedSlackInEyeDist。
    if (_hypot(c.x - sx, c.y - sy) > rivalSeedLimit) {
      trace?.add('  $tag rival-far ignored=$c');
      continue;
    }
    // 与首选隔开去重距离之外、得分又势均力敌 → 窗里有两个像虹膜的
    // 东西，谁是虹膜无法判定，整只眼判失败（不转比转错好）。
    trace?.add('  $tag AMBIGUOUS best=$kind runnerUp=$c');
    return null;
  }
  return PupilPoint(
    x: kind.x,
    y: kind.y,
    diameterPx: kind.diameter,
    areaPx: kind.areaPx.round(),
    circularity: kind.circularity,
    aspect: kind.aspect,
    percentile: kind.percentile,
  );
}

/// 灰度为 0..255 整数时的 (0,100] 百分位阈值：返回最小的 v 使得
/// 累计计数 ≥ total·pct/100。
int _percentile(Int32List hist, int total, double pct) {
  final int target = (total * pct / 100.0).ceil();
  var acc = 0;
  for (var v = 0; v < 256; v++) {
    acc += hist[v];
    if (acc >= target) return v;
  }
  return 255;
}

class _Blob {
  _Blob({
    required this.x,
    required this.y,
    required this.diameter,
    required this.areaPx,
    required this.circularity,
    required this.aspect,
    required this.percentile,
    required this.score,
  });

  final double x;
  final double y;
  final double diameter;
  final double areaPx;
  final double circularity;
  final double aspect;
  final double percentile;
  final double score;

  @override
  String toString() => 'd=${diameter.toStringAsFixed(1)} '
      'n=$areaPx circ=${circularity.toStringAsFixed(2)} '
      'xy=(${x.toStringAsFixed(0)},${y.toStringAsFixed(0)}) '
      'score=${score.toStringAsFixed(0)} p$percentile';
}
