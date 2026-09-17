// tools/gate/provenance.dart
//
// 测量产出的**来源绑定**。属 gatekeeper 势力范围。
//
// 为什么单列一条：
//   `out/` 是共享输出目录（CLAUDE.md §4），脏是预期的，所以它既不受冻结条件管、
//   也不进逐轮哈希基线。没有绑定，门禁就会拿**上一轮、或某个中途被改过的代码状态**
//   产出的数当本轮的数 —— 这与 r1 判决作废是同一个病（判决由两个不同代码状态的
//   测量拼成），只是换了个入口。r1 那次是靠主会话事后人工发现的，不是门禁抓到的。
//
// 两类输入，两种机制，**不能混用**：
//
//  1. **冻结的真值**（`out/P0_truth.json`）—— 存的是夹具真值，不是每轮产物。
//     按内容钉住：数值叶逐叶比对（`gate_P0.dart` 的 `truthDrift`）。
//     只允许经裁定的**纯表述**订正。
//
//  2. **测量产出**（成片清单 / 成片台摘要 / 成片残余 / 空洞扫描）—— **每轮本来就要
//     重生成**，按内容钉会天天报假警。改为按**产出它们的代码指纹**钉住：产物自己
//     记录「被测 lib 代码 + 生产它的 test/batch 代码」的 git blob 指纹，门禁校验该
//     指纹与当前树一致。不一致或缺字段 ⇒ `undecidable`，
//     **不许拿旧代码的数当本轮的数**。
//
// 指纹域**由门禁定义**，不由生产者定义：生产者若能把域收窄，这个检查就形同虚设
// （少记一个文件 = 那个文件改了也不响）。门禁要求的是 `kFingerprintRequiredDirs`
// 下的全部源码文件；生产者记录的是超集也接受，缺任何一个都判 `undecidable`。
//
// 第三件独立的事：`out/P0_anchors/composed/c01__cn_big_1inch.jpg` 是**量具自检的
// 标定靶**（`tools/gate/p0_eyeline.py selftest` 往它身上注入已知角、检查读回误差）。
// 它 untracked 且被 `.gitignore:21` 忽略 —— 哈希与 diff 两条路都堵死。
// 处置：把它按内容钉进门禁自己的滚动记录（见 [pinSelfcheckImage]），
// 并规定**被测代码指纹未变时它不许变**（同一份代码 + 同一份输入应产出同一份文件；
// 它变了而代码没变，就是被换过）。

import 'dart:convert';
import 'dart:io';

import 'sha256.dart';

/// 门禁要求的指纹域。**比生产者当前记录的域宽是故意的** ——
/// 测量脚本本身也是"产出这些数的代码"，改了脚本却不作废读数，等于换个地方藏东西。
const List<String> kFingerprintRequiredDirs = <String>['lib', 'test/batch'];

/// 参与指纹的源码后缀。**不收 `.pyc` / `__pycache__`**：
/// Python 一跑就写字节码，收进来会让"开跑/收尾两次指纹不一致"变成必然事件，
/// 从而天天误判成"跑的过程中代码被改了"。
const Set<String> kFingerprintSourceExt = <String>{'.dart', '.py'};

/// 量具自检的标定靶（`p0_eyeline.py selftest` / `p0_rigid_check.py selftest` 的 `--image`）。
///
/// **必须是 `test/` 下的冻结夹具源，不能是 `out/P0_anchors/composed/` 的成片。**
/// 那个目录是**可再生的混合态**（2026-09-17 实测只剩 93/110：一次脏树轮的覆盖
/// 把 17 张顶掉了），把量具的自证挂在一张随时可能不在的成片上，
/// "量具没自证"与"量具不准"会报成同一个结果。
/// 同理：不要把任何成片的**字节哈希**钉成冻结基准。
const String kSelfcheckImagePath = 'test/golden/src/g01.jpg';

/// 标定靶**换对象**的登记簿。键 `旧图 -> 新图`，值 = 理由（含日期与裁定人）。
///
/// 与判据分母那根钉同一个道理：内容钉只对**某一个文件**有意义。换了靶子而不换钉，
/// 唯一的症状是"内容变了"——而这正是 `tampered` 的判据，会报成"有人换过这张图"。
/// 一个看起来像篡改、实际只是换了靶的假阳性，比漏报更贵：它会烧掉整轮预算。
///
/// 所以换靶要同时满足：变更在代码里（受条款 2 的 SHA256 保护）**且**这一对在
/// 下面登记过理由。没登记 → 照旧按内容变处理（即 `tampered` 生效）。
/// 登记过 → 重钉并原样印进报告，**不判违规**：换靶本身不改变任何一份测量，
/// 真正约束标定靶的是条款 1 的 `test/` 冻结与这张图在 git 里的历史。
const Map<String, String> kSelfcheckRetargetLedger = <String, String>{
  'out/P0_anchors/composed/c01__cn_big_1inch.jpg -> $kSelfcheckImagePath':
      '2026-09-17 主会话裁定：标定靶改钉 `test/` 下的冻结夹具源。'
          '理由：原靶在可再生的 `out/P0_anchors/composed/` 里，已被一次脏树轮覆盖。',
};

/// 标定靶的内容钉。**首行 `sha256=<哈希>`，随后 `image=<路径>`**。
const String kSelfcheckImagePinPath = 'out/hashes_P0_selftest_image.txt';

/// git blob 哈希的形状。**用来把 `'unknown'` / `''` 这类占位值挡住** ——
/// 生产者取不到 git 时若写占位值，而门禁这边也取不到，两边会"看起来一致"。
final RegExp kBlobHashShape = RegExp(r'^[0-9a-f]{40}$|^[0-9a-f]{64}$');

String _slash(String p) => p.replaceAll('\\', '/');

String _relKey(String root, String full) {
  final String b = _slash(root).replaceAll(RegExp(r'/$'), '');
  final String f = _slash(full);
  if (b == '.' || b.isEmpty) return f.replaceAll(RegExp(r'^\./'), '');
  return f.startsWith('$b/') ? f.substring(b.length + 1) : f;
}

/// 门禁要求的指纹路径表：`kFingerprintRequiredDirs` 下的全部源码文件，
/// 仓库相对路径、正斜杠、已排序。
List<String> requiredFingerprintPaths({String root = '.'}) {
  final List<String> out = <String>[];
  for (final String dir in kFingerprintRequiredDirs) {
    final Directory d = Directory('$root/$dir');
    if (!d.existsSync()) continue;
    for (final FileSystemEntity e in d.listSync(recursive: true)) {
      if (e is! File) continue;
      final String p = _slash(e.path);
      if (p.contains('__pycache__')) continue;
      final int dot = p.lastIndexOf('.');
      if (dot < 0) continue;
      if (!kFingerprintSourceExt.contains(p.substring(dot))) continue;
      out.add(_relKey(root, p));
    }
  }
  out.sort();
  return out;
}

/// 当前树里这些路径的 git blob 哈希。
///
/// **`null` 是一个有区别的返回值**，含义是"取不到"，不是"一致"：
///  - git 起不来 / 非 0 退出 / 输出为空 ⇒ 整体返回 null；
///  - 返回空输出会被上层当成"没有不一致"，正是本项目反复记的那个形态
///    （仪表看不见对象时说了"没有"）。
///
/// 刻意用 `git hash-object <path>` 而不是 `git rev-parse HEAD:<path>`：
/// 前者按**文件内容**算，与提交时序、索引状态无关；工作区有未提交改动时它照样
/// 给出正确的内容指纹，而 `rev-parse HEAD:` 会说"这个文件在那个提交里长这样"，
/// 恰好答错问题。
Map<String, String>? currentBlobHashes(
  List<String> relPaths, {
  String root = '.',
}) {
  final Map<String, String> m = <String, String>{};
  for (final String p in relPaths) {
    ProcessResult r;
    try {
      // 刻意**不用** runInShell：本项目已因"从 Dart 起子进程、参数在 Windows 上
      // 被吃掉"栽过一次（grep 的模式常量，见 PITFALLS）。这里虽然只是普通路径，
      // 但走 shell 会把同一类失败面重新打开。git 是 .exe，PATH 解析不需要 shell。
      r = Process.runSync('git', <String>['hash-object', p], workingDirectory: root);
    } catch (_) {
      return null;
    }
    if (r.exitCode != 0) return null;
    final String h = (r.stdout as String).trim();
    if (h.isEmpty) return null;
    m[p] = h;
  }
  return m;
}

Object? digJson(Object? node, List<String> keys) {
  Object? cur = node;
  for (final String k in keys) {
    if (cur is! Map) return null;
    cur = cur[k];
  }
  return cur;
}

/// 一份测量产出的来源绑定结论。
///
/// [reasons] 非空即 `undecidable` —— **不是**"通过"，也**不是**"失败"：
/// 它表示这份产出不能用来判本轮的人。
class OutputBinding {
  /// 产出文件路径（仓库相对）。
  final String path;

  /// 指纹在文件里的位置，人读形式（如 `provenance.codeFingerprint`）。
  final String pointer;

  final List<String> reasons;
  final int requiredCount;
  final int matchedCount;
  final List<String> missingPaths;
  final List<String> mismatchPaths;
  final int extraCount;
  final Object? recordedRoundValid;
  final Object? recordedFnvnv;
  final int? recordedFileCount;

  OutputBinding({
    required this.path,
    required this.pointer,
    required this.reasons,
    required this.requiredCount,
    required this.matchedCount,
    required this.missingPaths,
    required this.mismatchPaths,
    required this.extraCount,
    this.recordedRoundValid,
    this.recordedFnvnv,
    this.recordedFileCount,
  });

  bool get ok => reasons.isEmpty;

  /// 单行结论，供控制台与 md 报告引用。
  String get tag => ok ? 'OK' : 'UNDECIDABLE';

  String describe() {
    if (ok) {
      return '$path[$pointer] OK：$matchedCount/$requiredCount 个受钉源码文件的 '
          'blob 哈希与当前树逐条一致'
          '${extraCount > 0 ? "（另有 $extraCount 个生产者多记的文件，忽略）" : ""}';
    }
    final List<String> bits = <String>[];
    if (missingPaths.isNotEmpty) {
      bits.add('**缺 ${missingPaths.length} 条**：${missingPaths.take(8).join("、")}'
          '${missingPaths.length > 8 ? " …" : ""}');
    }
    if (mismatchPaths.isNotEmpty) {
      bits.add('**${mismatchPaths.length} 条与当前树不一致**：'
          '${mismatchPaths.take(8).join("、")}${mismatchPaths.length > 8 ? " …" : ""}');
    }
    return '$path[$pointer] **不可判**：${reasons.join("；")}'
        '${bits.isEmpty ? "" : "。" + bits.join("；")}'
        '（对照：$requiredCount 条要求、$matchedCount 条一致）';
  }
}

/// 校验一份产出。缺失/类型不对/占位值/缺路径/哈希不一致，逐条写进 [OutputBinding.reasons]。
OutputBinding _verifyOne({
  required String path,
  required List<String> pointer,
  required Map<String, String>? current,
  required int requiredCount,
  required Map<String, dynamic>? doc,
  required String missingFileReason,
}) {
  final String ptrDesc = pointer.join('.');
  final List<String> reasons = <String>[];
  final List<String> missingPaths = <String>[];
  final List<String> mismatchPaths = <String>[];
  int matched = 0;
  int extra = 0;
  Object? roundValid;
  Object? fnv;
  int? fileCount;

  if (doc == null) {
    reasons.add(missingFileReason);
  } else if (current == null) {
    // 先把"门禁这边取不到"单独说清楚：否则会被读成"产出的指纹是错的"。
    reasons.add('门禁侧无法计算当前树的 git blob 指纹（git 起不来或非 0 退出），'
        '**本轮不可判** —— 取不到不等于一致');
  } else {
    final Object? fpRaw = digJson(doc, pointer);
    if (fpRaw is! Map) {
      reasons.add('没有 `${ptrDesc}` 块（或类型不对）。'
          '缺这个字段的产出**无法自证属于哪份代码**，不得当作本轮的数');
    } else {
      final Map<String, dynamic> fp = fpRaw.cast<String, dynamic>();
      // 开跑↔收尾的一致性旗标写在**指纹块的父层**（`provenance` 或
      // `summary.provenance`），不在指纹块里：指纹块是
      // `code_fingerprint.codeFingerprint()` 的返回（files/fnv1a64/blobHashes/
      // headCommit…），而 `roundVerdict()` 是**另一个函数、另一张表**
      // （codeStableDuringRun/roundValid/changedFiles/verdict），生产侧把两张表
      // 并排铺在同一层。所以要从 `pointer` 去掉末段那层取。
      //
      // 早先这里读的是 `fp['roundValid']`，深了一层 → 永远 null → 三份测量产出
      // 一律被判「无法自证来源」→ `allBound=false` → **每一轮都无条件作废**，
      // 与被测代码无关。修好后同一份产出实测 103/103 条 blob 与当前树相符。
      final Map<String, dynamic> verdict = pointer.length > 1
          ? (digJson(doc, pointer.sublist(0, pointer.length - 1)) as Map?)
                  ?.cast<String, dynamic>() ??
              <String, dynamic>{}
          : <String, dynamic>{};
      roundValid = verdict['roundValid'] ?? verdict['codeStableDuringRun'];
      fnv = fp['fnv1a64'];
      final Object? recRaw = fp['blobHashes'];
      if (recRaw is! Map) {
        reasons.add('`$ptrDesc.blobHashes` 缺失或类型不对');
      } else {
        final Map<String, String> rec =
            recRaw.map((Object? k, Object? v) => MapEntry('$k', '$v'));
        fileCount = (fp['files'] as num?)?.toInt() ?? rec.length;

        // **先看"开跑↔收尾"两次指纹是否一致**再比当前树：不一致说明这份数
        // 压根不属于任何一个稳定的代码状态（跑的过程中代码被改过），
        // 此时再比当前树是多余的，且会把原因说错。
        if (roundValid != true) {
          reasons.add('`$ptrDesc.roundValid`/`codeStableDuringRun` 不是 true'
              '（实测 ${roundValid ?? "缺失"}）—— 产出过程中被测代码被改过，'
              '这份数不属于任何稳定的代码版本');
        }

        // 占位值先挡掉：`'unknown'` / `''` 是 git 没跑成功时最容易被写下的东西，
        // 而它在两侧都失败时会"看起来一致"。
        final List<String> placeholders =
            rec.entries.where((MapEntry<String, String> e) => !kBlobHashShape.hasMatch(e.value))
                .map((MapEntry<String, String> e) => '${e.key}=${e.value.isEmpty ? "(空)" : e.value}')
                .toList();
        if (placeholders.isNotEmpty) {
          reasons.add('`$ptrDesc.blobHashes` 里有 ${placeholders.length} 条不是合法的 '
              'git blob 哈希（git 大概没跑成功）：'
              '${placeholders.take(5).join("、")}');
        }

        for (final String p in current.keys) {
          final String? got = rec[p];
          if (got == null) {
            missingPaths.add(p);
          } else if (got != current[p]) {
            mismatchPaths.add(p);
          } else {
            matched++;
          }
        }
        extra = rec.keys.where((String k) => !current.containsKey(k)).length;
        missingPaths.sort();
        mismatchPaths.sort();
        if (missingPaths.isNotEmpty) {
          reasons.add('产出没有记录 ${missingPaths.length} 个门禁要求的文件');
        }
        if (mismatchPaths.isNotEmpty) {
          reasons.add('${mismatchPaths.length} 个文件的 blob 哈希与当前树不一致'
              '（＝这些数是**别的代码**跑出来的）');
        }
      }
    }
  }

  return OutputBinding(
    path: path,
    pointer: ptrDesc,
    reasons: reasons,
    requiredCount: requiredCount,
    matchedCount: matched,
    missingPaths: missingPaths,
    mismatchPaths: mismatchPaths,
    extraCount: extra,
    recordedRoundValid: roundValid,
    recordedFnvnv: fnv,
    recordedFileCount: fileCount,
  );
}

Map<String, dynamic>? _readJsonOrNull(String path) {
  final File f = File(path);
  if (!f.existsSync()) return null;
  try {
    final Object? d = jsonDecode(f.readAsStringSync());
    return d is Map<String, dynamic> ? d : null;
  } catch (_) {
    return null;
  }
}

/// 三份测量产出的来源绑定。`out/P0_truth.json` 不在其中 —— 它是**真值**不是产出，
/// 走内容钉住（`truthDrift`），两种机制刻意不混用。
///
/// `out/P0_compose_items.jsonl` 也不单独校验：它的每一行由成片台写出，
/// 成片台的 `P0_compose_summary.json` 才是它的自证；两者在同一轮同一次运行里产生，
/// 分列两处会让报告出现"同一批数据两个结论"。
///
/// `current` 由调用方算好传进来（`null` = 门禁侧取不到 git），**不在这里重算**：
/// 一次调用要跑上百次 `git hash-object`，重算既慢又会引入"两次算的不是同一棵树"。
List<OutputBinding> verifyMeasurementOutputs({
  required List<String> required,
  required Map<String, String>? current,
  String root = '.',
}) {
  OutputBinding one(String path, List<String> pointer) => _verifyOne(
        path: path,
        pointer: pointer,
        current: current,
        requiredCount: required.length,
        doc: _readJsonOrNull('$root/$path'),
        missingFileReason: '文件不存在，或存在但解析不出 JSON 对象（两种情形都不许当成"这轮没这份数据"）',
      );

  return <OutputBinding>[
    one('out/P0_compose_summary.json', <String>['provenance', 'codeFingerprint']),
    one('out/P0_output_residual.json',
        <String>['summary', 'provenance', 'codeFingerprint']),
    one('out/P0_alpha_holes.json', <String>['provenance', 'codeFingerprint']),
  ];
}

/// 门禁自己用的代码指纹摘要：把所有 `路径:blob哈希` 排序后拼起来取 FNV-1a 64。
///
/// **只用于跟门禁自己的历史比较**（标定靶的内容钉要和"当时是哪份代码"配对），
/// 不与生产者的 `fnv1a64` 做跨实现比对 —— 那是另一条判据，用 `blobHashes` 逐条比。
String fingerprintDigest(Map<String, String> hashes) {
  final List<String> ks = hashes.keys.toList()..sort();
  final String joined = ks.map((String k) => '$k:${hashes[k]}').join('\n');
  int h = 0xcbf29ce484222325;
  for (final int c in joined.codeUnits) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

/// 标定靶的内容钉。
class SelfcheckPin {
  final String path;
  final bool fileExists;
  final bool baselineEstablished;
  final String? currentHash;
  final String? pinnedHash;
  final String? pinnedImage;

  /// 钉这条记录时，门禁看到的代码指纹摘要。
  final String? pinnedCode;

  /// 本轮看到的代码指纹摘要。
  final String? currentCode;

  /// 钉里记的标定靶**换成了本轮的靶**（且已在 `kSelfcheckRetargetLedger` 登记）。
  /// 为真时 `changed` / `tampered` 一律不成立 —— 比的是两份**不同文件**的哈希，
  /// 那种"不一致"没有任何证据力。
  final bool retargeted;

  SelfcheckPin({
    required this.path,
    required this.fileExists,
    required this.baselineEstablished,
    required this.currentHash,
    required this.pinnedHash,
    required this.pinnedImage,
    this.pinnedCode,
    this.currentCode,
    this.retargeted = false,
  });

  /// 内容变了。**换靶时恒为假** —— 换了靶子还按"内容变了"判，就是在拿
  /// 两份不同文件的哈希做比较，结论只能是噪声。
  bool get changed =>
      !retargeted &&
      !baselineEstablished &&
      pinnedHash != null &&
      currentHash != null &&
      pinnedHash != currentHash;

  /// 钉里记的那份代码 vs 现在。
  bool get codeChanged =>
      pinnedCode != null && currentCode != null && pinnedCode != currentCode;

  /// **同一份代码 + 同一份输入产不出两份不同内容的文件。**
  ///
  /// 成立条件：内容变了、而代码指纹没变（且两侧都有记录）。
  /// 代码也变了的情况下内容跟着变是预期的（重跑产物），此时只登记不判违规。
  bool get tampered => changed && pinnedCode != null && currentCode != null && !codeChanged;

  String describe() {
    if (!fileExists) {
      return '$path **不存在**，无法钉住（本轮量具自检会因此失败）';
    }
    if (retargeted) {
      return '标定靶**换过**：钉里记的是 `$pinnedImage`，本轮指向 `$path`'
          '（已在 `kSelfcheckRetargetLedger` 登记）。'
          '内容钉已按新靶重钉 sha256=${_short(currentHash)}；'
          '**本轮不作"内容变了"的判定**——两份不同文件的哈希没有可比性。';
    }
    if (baselineEstablished) {
      return '$path 首轮建立内容钉 sha256=${_short(currentHash)}'
          '（同时记下当时的代码指纹摘要 ${pinnedCode ?? "?"}），本轮不判 FAIL';
    }
    if (currentHash == null) {
      return '$path 存在但读不出内容，无法比对内容钉';
    }
    if (pinnedHash == null) {
      return '$path 的内容钉文件存在但读不出基线哈希（被改坏了？）';
    }
    if (!changed) {
      return '$path 与内容钉一致（sha256=${_short(currentHash)}）'
          '${codeChanged ? "；期间代码已变（$pinnedCode→$currentCode）但标定靶未变，属预期" : ""}';
    }
    if (tampered) {
      return '$path **内容已变而代码未变**（钉 ${_short(pinnedHash)} → 现 '
          '${_short(currentHash)}，代码摘要仍为 $currentCode）——'
          '同一份代码 + 同一份输入产不出两份不同内容的文件，该文件被换过';
    }
    return '$path 内容已变：钉 ${_short(pinnedHash)} → 现 ${_short(currentHash)}，'
        '同时代码指纹摘要 ${pinnedCode ?? "?"} → ${currentCode ?? "?"}，'
        '按重跑产物登记（非违规）';
  }

  static String _short(String? h) =>
      h == null ? "(无)" : (h.length <= 16 ? h : '${h.substring(0, 16)}…');
}

/// 读（必要时建立或重钉）标定靶的内容钉。
///
/// 钉文件三行：`sha256=<标定靶哈希>`、`code=<钉时的代码指纹摘要>`、`image=<路径>`。
/// 之所以要记 `code`：只钉内容的话，代码一改、产物跟着重生成，读数就会天天变，
/// 这个钉会退化成噪声；配上代码摘要才能区分"换个代码重跑"与"代码没动但文件被换"。
SelfcheckPin pinSelfcheckImage({
  String root = '.',
  String? codeDigest,
  bool codeBinds = false,
}) {
  final String p = '$root/$kSelfcheckImagePath';
  final String pinPath = '$root/$kSelfcheckImagePinPath';
  final File f = File(p);
  final File pin = File(pinPath);

  String? cur;
  if (f.existsSync()) {
    try {
      cur = _sha256Hex(f.readAsBytesSync());
    } catch (_) {
      cur = null;
    }
  }

  void write(String hash, String? code) {
    pin
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('sha256=$hash\n'
          'code=${code ?? ""}\n'
          'image=$kSelfcheckImagePath\n');
  }

  if (!pin.existsSync()) {
    if (f.existsSync() && cur != null) {
      write(cur, codeDigest);
      return SelfcheckPin(
        path: kSelfcheckImagePath,
        fileExists: true,
        baselineEstablished: true,
        currentHash: cur,
        pinnedHash: null,
        pinnedImage: null,
        pinnedCode: codeDigest,
        currentCode: codeDigest,
      );
    }
    return SelfcheckPin(
      path: kSelfcheckImagePath,
      fileExists: f.existsSync(),
      baselineEstablished: false,
      currentHash: cur,
      pinnedHash: null,
      pinnedImage: null,
      currentCode: codeDigest,
    );
  }

  String? pinnedHash;
  String? pinnedImage;
  String? pinnedCode;
  for (final String line in pin.readAsLinesSync()) {
    if (line.startsWith('sha256=')) pinnedHash = line.substring(7).trim();
    if (line.startsWith('image=')) pinnedImage = line.substring(6).trim();
    if (line.startsWith('code=')) {
      final String v = line.substring(5).trim();
      pinnedCode = v.isEmpty ? null : v;
    }
  }
  final bool retargeted = pinnedImage != null &&
      pinnedImage != kSelfcheckImagePath &&
      kSelfcheckRetargetLedger.containsKey('$pinnedImage -> $kSelfcheckImagePath');
  final SelfcheckPin out = SelfcheckPin(
    path: kSelfcheckImagePath,
    fileExists: f.existsSync(),
    baselineEstablished: false,
    currentHash: cur,
    pinnedHash: pinnedHash,
    pinnedImage: pinnedImage,
    pinnedCode: pinnedCode,
    currentCode: codeDigest,
    retargeted: retargeted,
  );
  // 换靶：钉记的是**另一张图**的哈希，比下去只会得到"内容变了"这个假阳性。
  // 只认登记过的那一对（未登记的一对 `retargeted` 为假，照旧走内容变/被换的判定）。
  if (retargeted && cur != null) {
    write(cur, codeDigest);
  }
  // 什么时候前移这根钉：
  //   · **只在 `codeBinds` 时**。只有测量产出确实来自当前代码，才能断定标定靶
  //     也是当前代码产出的。产出绑不上时，盘上的标定靶是**上一版代码**留下的，
  //     把它钉到当前代码摘要上就是**就地洗白**，下一轮再也看不见。
  //   · **`tampered` 时绝不前移**：那会把一次替换就地洗白，同理。
  //   · 内容没变、只是代码变了 → **只把代码摘要前移**（内容还是那份内容，
  //     只是产出它的代码换了一版）。这一步不是可有可无的洁癖：
  //     不前移的话，钉永远停在最老的那版代码上，于是"代码 X 产的内容 A"与
  //     "代码 Y 产的内容 B"之间那次替换，会因为 X≠Y 而被判成"重跑产物"——
  //     **正是在代码连续变动期间发生的那次替换会被整段漏掉。**
  if (codeBinds && cur != null && !out.tampered &&
      (out.pinnedHash != cur || out.pinnedCode != codeDigest)) {
    write(cur, codeDigest);
  }
  return out;
}

/// 一次来源绑定的完整结论。
class ProvenanceReport {
  final List<OutputBinding> bindings;
  final SelfcheckPin pin;

  /// 当前树的 `路径→blob哈希`。`null` = 门禁侧取不到 git。
  final Map<String, String>? currentHashes;

  /// **实际参与指纹的域文件清单**（排序）。
  ///
  /// 为什么要把清单本身带在报告里，而不是只报个数：本轮之前已经栽过两次同类 ——
  /// `lib` 域 **29 vs 101** 个文件（两边各按自己的规则枚举，数目对不上才发现），
  /// 以及 `files` 计数相等而集合不同的情形。**"数目相等 ≠ 内容相同"**，
  /// 只印个数的话，下一次"数目恰好相等而集合不同"就还是会滑过去。
  /// 所以清单每轮原样打印，可被逐行 diff。
  ///
  /// 这是**门禁声明的**域（`requiredFingerprintPaths` 枚举得到），
  /// 与 `currentHashes!` 的键集恒等（`currentBlobHashes` 全成或全空），
  /// 故 git 不可用时它仍然可用 —— 域的定义不依赖 git。
  final List<String> requiredPaths;

  ProvenanceReport({
    required this.bindings,
    required this.pin,
    required this.currentHashes,
    required this.requiredPaths,
  });

  /// 声明域的文件数。**与 git 是否可用无关** —— 取不到哈希是"这一轮不可判"，
  /// 不该顺带把"域里有几个文件"也报成 0（那是把仪表故障读成样本消失）。
  int get requiredCount => requiredPaths.length;

  String? get codeDigest {
    final Map<String, String>? h = currentHashes;
    return h == null ? null : fingerprintDigest(h);
  }

  /// 三份产出是否都绑上了当前代码。
  bool get allBound => bindings.every((OutputBinding b) => b.ok);

  /// 本轮因来源绑定而无效的理由。空表 = 绑定成立。
  List<String> invalidReasons() {
    final List<String> r = <String>[];
    for (final OutputBinding b in bindings) {
      if (!b.ok) {
        r.add('测量产出 `${b.path}` 不可自证属于当前代码：${b.reasons.join("；")}');
      }
    }
    if (pin.tampered) {
      r.add('量具标定靶 `${pin.path}` 内容已变而代码未变：${pin.describe()}');
    }
    return r;
  }

  /// 报告用的一句话总括（无论绑没绑上都要出现，**不许静默**）。
  String summary() {
    final List<String> bad =
        bindings.where((OutputBinding b) => !b.ok).map((OutputBinding b) => b.path).toList();
    final String head = bad.isEmpty
        ? '3 份测量产出均可自证与当前树同源'
            '（受钉源码 ${requiredCount} 个文件 = `lib/` 全部 `.dart` + `test/batch/` 全部 `.dart`/`.py`；'
            '代码摘要 ${codeDigest ?? "?"}）'
        : '**${bad.length}/3 份测量产出无法自证来源**：${bad.join("、")}'
            '（受钉源码 ${requiredCount} 个文件）';
    return '$head；标定靶：${pin.describe()}';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'requiredCount': requiredCount,
        'requiredPaths': requiredPaths,
        'requiredDirs': kFingerprintRequiredDirs,
        'requiredExtensions': kFingerprintSourceExt.toList()..sort(),
        'gitAvailable': currentHashes != null,
        'codeDigest': codeDigest,
        'allBound': allBound,
        'reasons': invalidReasons(),
        'summary': summary(),
        'bindings': bindings
            .map((OutputBinding b) => <String, dynamic>{
                  'path': b.path,
                  'pointer': b.pointer,
                  'tag': b.tag,
                  'ok': b.ok,
                  'reasons': b.reasons,
                  'requiredCount': b.requiredCount,
                  'matchedCount': b.matchedCount,
                  'missingPaths': b.missingPaths,
                  'mismatchPaths': b.mismatchPaths,
                  'extraCount': b.extraCount,
                  'recordedRoundValid': b.recordedRoundValid,
                  'recordedFileCount': b.recordedFileCount,
                  'describe': b.describe(),
                })
            .toList(),
        'selfcheckPin': <String, dynamic>{
          'path': pin.path,
          'fileExists': pin.fileExists,
          'baselineEstablished': pin.baselineEstablished,
          'currentHash': pin.currentHash,
          'pinnedHash': pin.pinnedHash,
          'pinnedCode': pin.pinnedCode,
          'currentCode': pin.currentCode,
          'pinnedImage': pin.pinnedImage,
          'retargeted': pin.retargeted,
          'changed': pin.changed,
          'tampered': pin.tampered,
          'describe': pin.describe(),
        },
      };
}

/// 一次算齐：当前树指纹 + 三份产出的绑定 + 标定靶内容钉。
///
/// **必须一次算齐**，不能分两处调用：标定靶要不要重钉，取决于产出有没有绑上代码
/// （见 `pinSelfcheckImage` 的 `codeBinds`），分成两次调用就会各算各的、把这个依赖丢掉。
ProvenanceReport provenanceReport({String root = '.'}) {
  final List<String> required = requiredFingerprintPaths(root: root);
  final Map<String, String>? current = currentBlobHashes(required, root: root);
  final List<OutputBinding> bindings =
      verifyMeasurementOutputs(required: required, current: current, root: root);
  final bool allBound = bindings.every((OutputBinding b) => b.ok);
  final SelfcheckPin pin = pinSelfcheckImage(
    root: root,
    codeDigest: current == null ? null : fingerprintDigest(current),
    codeBinds: allBound,
  );
  return ProvenanceReport(
    bindings: bindings,
    pin: pin,
    currentHashes: current,
    requiredPaths: required,
  );
}

/// 报告里那一节的渲染。抽成公开函数是为了能**自测**：
/// 这段文本只有 `gate_P0.dart` 的 `main()` 走到最后才会生成，留在私有函数里就
/// 只能靠跑一整轮（含 40 分钟的 `flutter test dev_selfcheck`）才发现它崩了。
String provenanceMdSection(Map<String, dynamic>? pv) {
  if (pv == null) {
    return '- **无法判定**：缺 `provenance`（来源绑定未产出）。'
        '**不默认清白** —— 缺这一节时，盘上的读数可能是上一轮的遗留。';
  }
  final StringBuffer b = StringBuffer();
  b.writeln('- ${pv['summary'] ?? "（无摘要）"}');
  b.writeln('- 指纹域（**由门禁定义，不由生产者定义**）：'
      '`${(pv['requiredDirs'] as List<dynamic>? ?? <dynamic>[]).join("`、`")}` 下全部 '
      '`${(pv['requiredExtensions'] as List<dynamic>? ?? <dynamic>[]).join("` / `")}`，'
      '共 ${pv['requiredCount']} 个文件；门禁侧 git 可用 = ${pv['gitAvailable']}；'
      '代码摘要 `${pv['codeDigest'] ?? "?"}`。'
      '生产者记录的是超集也接受，**缺任何一个都判不可判**——域若能被生产者收窄，'
      '这个检查就形同虚设（少记一个文件 = 那个文件改了也不响）。');
  // 清单本身，逐行 —— 不只是个数。**"数目相等 ≠ 内容相同"** 这个形状在本项目
  // 已经出现过两次（`lib` 域 29 vs 101；`files` 计数相等而集合不同），
  // 只印个数的检查第三次还会被同样的方式绕过。
  final List<dynamic> dom = pv['requiredPaths'] as List<dynamic>? ?? <dynamic>[];
  b.writeln('- **实际域文件清单（本轮逐行，可直接 diff 上一轮）**，共 ${dom.length} 条：');
  b.writeln();
  b.writeln('```');
  for (final dynamic p in dom) {
    b.writeln(p);
  }
  b.writeln('```');
  b.writeln();
  for (final dynamic rawB in (pv['bindings'] as List<dynamic>? ?? <dynamic>[])) {
    final Map<String, dynamic> bd = (rawB as Map).cast<String, dynamic>();
    b.writeln('  - `${bd['path']}` → **${bd['tag']}**：${bd['describe']}');
  }
  final Map<String, dynamic> pin =
      ((pv['selfcheckPin'] as Map?) ?? <String, dynamic>{}).cast<String, dynamic>();
  b.writeln('- **量具标定靶**（`tools/gate/p0_eyeline.py selftest` 注入已知角用的那张图，'
      '`${pin['path']}`）：${pin['describe']}。');
  b.writeln('  - 标定靶是 `test/` 下的**冻结夹具源**（入库、被条款 1 的 `test/` 冻结'
      '与 git 历史双重覆盖）——**不是** `out/P0_anchors/composed/` 的成片。'
      '后者是可再生的混合态：2026-09-17 实测只剩 93/110（一次脏树轮的覆盖顶掉了 17 张）。'
      '把量具的自证挂在一张随时可能不在的成片上，「量具没自证」与「量具不准」'
      '会报成同一个结果。');
  b.writeln('  - 钉里同时记「当时是哪份代码」（代码摘要）：只钉内容的话，代码一改、'
      '产物跟着重生成，读数天天变，这个钉会退化成噪声；配上代码摘要才能把'
      '「换份代码重跑」（预期）与「代码没动但文件被换」（不允许）分开。');
  b.writeln('  - **重钉只发生在前一条成立时**（测量产出确实绑上了当前代码）；'
      '产出绑不上时盘上的标定靶是**上一版代码**留下的，把它钉到当前代码摘要上'
      '就是就地洗白，下一轮再也看不见。');
  if (pin['retargeted'] == true) {
    b.writeln('  - **本轮标定靶换过对象**：钉里记的是 `${pin['pinnedImage']}`，'
        '本轮指向 `${pin['path']}`（已在 `kSelfcheckRetargetLedger` 登记）。'
        '内容钉已按新靶重钉，**本轮不作「内容变了」的判定** ——'
        '两份**不同文件**的哈希做比较，那个"不一致"没有任何证据力，'
        '只会报成一次看起来像篡改的假阳性。');
  }
  final List<dynamic> reasons = pv['reasons'] as List<dynamic>? ?? <dynamic>[];
  if (reasons.isEmpty) {
    b.writeln('- 结论：**绑定成立**，本轮读数可用于判人。');
  } else {
    b.writeln('- 结论：**绑定不成立 → 整轮作废**（全部条目 pass=false、manual=true，'
        '不消耗实现方修复轮次）。逐条理由：');
    for (final dynamic r in reasons) {
      b.writeln('  - $r');
    }
  }
  return b.toString();
}

/// 纯 Dart SHA-256（`tools/gate/sha256.dart`，已对 NIST 向量与 `sha256sum` 逐位校验）。
/// 这里刻意**不复用** `gate_P0.dart` 的私有 `_sha256`：那个函数把"文件读不出来"
/// 压成 null，而标定靶的钉必须能区分"读不出来"与"内容相同"。
String _sha256Hex(List<int> bytes) => sha256Hex(bytes);
