// test/gate/provenance_test.dart
//
// **测量产出「来源绑定」判定的自检。**
//
// 存在理由：`out/` 是共享输出目录，不受冻结约束，所以门禁可以读到**上一轮**
// 或**某个中途被改过的代码状态**产出的数，而不自知——这与 r1 判决作废同源
// （判决由两个不同代码状态的测量拼成），只是换了个入口。
// `tools/gate/provenance.dart` 就是对它的判定；本文件给这个判定做正负两侧控制。
//
// **每条判定都必须能在"该红"的地方红**。一个永远返回"绑定成立"的实现
// 比没有绑定更糟：它会给全自动模式一个假的"本轮数据可信"。
// 所以下面既有正例（构造一份真能绑上的产出，断言它 OK），也有反例。
//
// 属 gatekeeper 势力范围（test/gate/）。

// flutter_test 是 dev_dependency。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';

import 'dart:convert';
import 'dart:io';

import '../../tools/gate/provenance.dart';

/// 沙箱必须建在**仓库内部**：`git hash-object` 需要有仓库上下文。
/// 用 `out/tmp_*` 前缀是因为 `.gitignore` 已经忽略它（`out/tmp_*/`）。
const String kSandbox = 'out/tmp_gk_prov_test';

void _write(String rel, String content) {
  final File f = File('$kSandbox/$rel');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
}

void _rmSandbox() {
  final Directory d = Directory(kSandbox);
  if (d.existsSync()) d.deleteSync(recursive: true);
}

/// 构造一个沙箱：`lib/` 与 `test/batch/` 里各放几个文件（受钉域），
/// 其余后缀/目录用来验证**域本身没被放宽**。
void _buildSandbox() {
  _rmSandbox();
  _write('lib/a.dart', 'void a() {}\n');
  _write('lib/nested/b.dart', 'void b() {}\n');
  _write('test/batch/c.dart', 'void c() {}\n');
  _write('test/batch/d.py', 'print(1)\n');
  // 下面这些**不该**进受钉域：
  _write('lib/readme.md', 'not source\n');
  _write('test/batch/__pycache__/d.cpython-311.pyc', 'bytecode\n');
  _write('test/golden/src/g01.jpg', 'not source\n');
  _write('out/other.json', '{}\n');
}

Map<String, String> _current() =>
    currentBlobHashes(requiredFingerprintPaths(root: kSandbox), root: kSandbox)!;

/// 写一份成片台摘要，`blobHashes` 按传入的地图；`roundValid` 可控。
void _writeSummary({
  required Map<String, String> blobHashes,
  Object? roundValid = true,
  Object? files,
}) {
  _write(
    'out/P0_compose_summary.json',
    const JsonEncoder.withIndent(' ').convert(<String, dynamic>{
      'generatedBy': 'sandbox',
      'provenance': <String, dynamic>{
        'codeFingerprint': <String, dynamic>{
          'files': files ?? blobHashes.length,
          'fnv1a64': 'deadbeefdeadbeef',
          'blobHashes': blobHashes,
          'roundValid': roundValid,
        },
      },
    }),
  );
}

void _writeResidual(Map<String, String> blobHashes) {
  _write(
    'out/P0_output_residual.json',
    const JsonEncoder.withIndent(' ').convert(<String, dynamic>{
      'summary': <String, dynamic>{
        'provenance': <String, dynamic>{
          'codeFingerprint': <String, dynamic>{
            'blobHashes': blobHashes,
            'roundValid': true,
          },
        },
      },
    }),
  );
}

void _writeAlphaHoles(Map<String, String> blobHashes) {
  _write(
    'out/P0_alpha_holes.json',
    const JsonEncoder.withIndent(' ').convert(<String, dynamic>{
      'provenance': <String, dynamic>{
        'codeFingerprint': <String, dynamic>{
          'blobHashes': blobHashes,
          'roundValid': true,
        },
      },
    }),
  );
}

void main() {
  setUpAll(_buildSandbox);
  tearDownAll(_rmSandbox);

  group('受钉域', () {
    test('域 = lib/ 全部 .dart + test/batch/ 全部 .dart/.py，且不收 .md/.pyc/.jpg', () {
      final List<String> paths = requiredFingerprintPaths(root: kSandbox);
      expect(paths, contains('lib/a.dart'));
      expect(paths, contains('lib/nested/b.dart'));
      expect(paths, contains('test/batch/c.dart'));
      expect(paths, contains('test/batch/d.py'));
      expect(paths.any((String p) => p.contains('__pycache__')), isFalse,
          reason: 'Python 一跑就写字节码，收进来会让"开跑/收尾两次指纹不一致"变成必然事件');
      expect(paths, isNot(contains('lib/readme.md')));
      expect(paths, isNot(contains('test/golden/src/g01.jpg')));
      expect(paths, isNot(contains('out/other.json')));
      expect(paths, isNot(contains('out/P0_compose_summary.json')));
    });
  });

  group('三份测量产出的绑定', () {
    test('正例：三份都记了完整且一致的 blobHashes → 全部 OK，invalidReasons 为空', () {
      final Map<String, String> h = _current();
      _writeSummary(blobHashes: h);
      _writeResidual(h);
      _writeAlphaHoles(h);
      final List<OutputBinding> bs =
          verifyMeasurementOutputs(required: requiredFingerprintPaths(root: kSandbox), current: h, root: kSandbox);
      expect(bs.length, 3);
      for (final OutputBinding b in bs) {
        expect(b.ok, isTrue, reason: '${b.path} 应为 OK，实际：${b.describe()}');
        expect(b.matchedCount, h.length);
        expect(b.missingPaths, isEmpty);
        expect(b.mismatchPaths, isEmpty);
      }
    });

    test('反例：整块缺失 → 不可判（不是"通过"，也不是"失败"）', () {
      final Map<String, String> h = _current();
      _write('out/P0_alpha_holes.json', '{"total": 87}\n');
      final OutputBinding b = verifyMeasurementOutputs(
        required: requiredFingerprintPaths(root: kSandbox),
        current: h,
        root: kSandbox,
      )[2];
      expect(b.ok, isFalse);
      expect(b.reasons.join(), contains('provenance.codeFingerprint'));
    });

    test('反例：少记一个文件（数目**不相等**）→ 不可判且点名缺了谁', () {
      final Map<String, String> h = Map<String, String>.from(_current())..remove('lib/nested/b.dart');
      _writeSummary(blobHashes: h);
      _writeResidual(h);
      _writeAlphaHoles(h);
      final OutputBinding b = verifyMeasurementOutputs(
        required: requiredFingerprintPaths(root: kSandbox),
        current: _current(),
        root: kSandbox,
      ).first;
      expect(b.ok, isFalse);
      expect(b.missingPaths, contains('lib/nested/b.dart'));
    });

    test('反例：**数目相等**但内容不同（丢一条 + 补一条）→ 仍须判不可判', () {
      // 这是条款 7 那个缺陷的同源形态：只比键的交集、或只比条数，
      // "删一个 + 加一个"完全隐形。这里必须比**路径集合**。
      final Map<String, String> h = Map<String, String>.from(_current())
        ..remove('lib/a.dart')
        ..['lib/readme.md'] = '0000000000000000000000000000000000000000';
      expect(h.length, _current().length, reason: '构造前提：条数与当前树相等');
      _writeSummary(blobHashes: h);
      _writeResidual(h);
      _writeAlphaHoles(h);
      final OutputBinding b = verifyMeasurementOutputs(
        required: requiredFingerprintPaths(root: kSandbox),
        current: _current(),
        root: kSandbox,
      ).first;
      expect(b.ok, isFalse, reason: '条数相等不等于内容相同');
      expect(b.missingPaths, contains('lib/a.dart'));
    });

    test('反例：某文件哈希与当前树不一致 → 不可判且点名是哪个文件', () {
      final Map<String, String> h = Map<String, String>.from(_current())
        ..['lib/a.dart'] = '1111111111111111111111111111111111111111';
      _writeSummary(blobHashes: h);
      _writeResidual(h);
      _writeAlphaHoles(h);
      final OutputBinding b = verifyMeasurementOutputs(
        required: requiredFingerprintPaths(root: kSandbox),
        current: _current(),
        root: kSandbox,
      ).first;
      expect(b.ok, isFalse);
      expect(b.mismatchPaths, contains('lib/a.dart'));
    });

    test('反例：roundValid=false（跑的过程中代码被改过）→ 不可判', () {
      final Map<String, String> h = _current();
      _writeSummary(blobHashes: h, roundValid: false);
      _writeResidual(h);
      _writeAlphaHoles(h);
      final OutputBinding b = verifyMeasurementOutputs(
        required: requiredFingerprintPaths(root: kSandbox),
        current: h,
        root: kSandbox,
      ).first;
      expect(b.ok, isFalse);
      expect(b.reasons.join(), contains('不是 true'));
    });

    test('反例：占位值 unknown / 空串 → 不可判（两侧都失败时不许"看起来一致"）', () {
      final Map<String, String> h = Map<String, String>.from(_current())
        ..['lib/a.dart'] = 'unknown'
        ..['lib/nested/b.dart'] = '';
      _writeSummary(blobHashes: h);
      _writeResidual(h);
      _writeAlphaHoles(h);
      final OutputBinding b = verifyMeasurementOutputs(
        required: requiredFingerprintPaths(root: kSandbox),
        current: h,
        root: kSandbox,
      ).first;
      expect(b.ok, isFalse, reason: '取了占位值时两侧会"一致"，这正是要挡的假绿');
      expect(b.reasons.join(), contains('不是合法的'));
    });

    test('反例：门禁侧取不到 git（current == null）→ 不可判，且理由说的是"取不到"', () {
      final Map<String, String> h = _current();
      _writeSummary(blobHashes: h);
      _writeResidual(h);
      _writeAlphaHoles(h);
      final OutputBinding b = verifyMeasurementOutputs(
        required: requiredFingerprintPaths(root: kSandbox),
        current: null,
        root: kSandbox,
      ).first;
      expect(b.ok, isFalse);
      expect(b.reasons.join(), contains('取不到不等于一致'));
    });

    test('反例：文件不存在 → 不可判', () {
      _rmSandbox();
      _buildSandbox();
      final OutputBinding b = verifyMeasurementOutputs(
        required: requiredFingerprintPaths(root: kSandbox),
        current: _current(),
        root: kSandbox,
      ).first;
      expect(b.ok, isFalse);
      expect(b.reasons.join(), contains('文件不存在'));
    });

    test('反例：文件在但解析不出 JSON 对象 → 不可判，且理由不把它说成"没有数据"', () {
      // 缺失与损坏必须**分得开**：前者是"这轮没跑"，后者是"跑出来的东西坏了"。
      // 两者都压成"没这份数据"就会让一次损坏看起来像一次正常的空轮。
      _rmSandbox();
      _buildSandbox();
      _write('out/P0_compose_summary.json', '{ 这不是 JSON');
      final OutputBinding b = verifyMeasurementOutputs(
        required: requiredFingerprintPaths(root: kSandbox),
        current: _current(),
        root: kSandbox,
      ).first;
      expect(b.ok, isFalse);
      expect(b.reasons.join(), contains('解析不出 JSON 对象'));
    });
  });

  group('量具标定靶的内容钉', () {
    const String imgRel = kSelfcheckImagePath;

    void freshPin() {
      final File f = File('$kSandbox/$kSelfcheckImagePinPath');
      if (f.existsSync()) f.deleteSync();
    }

    test('首轮：有图无钉 → 建立基线，不判 FAIL，并落盘钉文件', () {
      freshPin();
      _write(imgRel, 'IMAGE-A');
      final SelfcheckPin p = pinSelfcheckImage(root: kSandbox, codeDigest: 'aaa', codeBinds: true);
      expect(p.baselineEstablished, isTrue);
      expect(p.changed, isFalse);
      expect(p.tampered, isFalse);
      expect(File('$kSandbox/$kSelfcheckImagePinPath').existsSync(), isTrue);
    });

    test('内容未变 → 一致，不报任何异常', () {
      freshPin();
      _write(imgRel, 'IMAGE-A');
      pinSelfcheckImage(root: kSandbox, codeDigest: 'aaa', codeBinds: true);
      final SelfcheckPin p = pinSelfcheckImage(root: kSandbox, codeDigest: 'aaa', codeBinds: true);
      expect(p.changed, isFalse);
      expect(p.tampered, isFalse);
    });

    test('内容变了 + 代码没变 → **判被换过**（同一份代码产不出两份不同内容的文件）', () {
      freshPin();
      _write(imgRel, 'IMAGE-A');
      pinSelfcheckImage(root: kSandbox, codeDigest: 'aaa', codeBinds: true);
      _write(imgRel, 'IMAGE-B');
      final SelfcheckPin p = pinSelfcheckImage(root: kSandbox, codeDigest: 'aaa', codeBinds: true);
      expect(p.changed, isTrue);
      expect(p.tampered, isTrue, reason: '代码摘要未变而内容变了，就是被换过');
      expect(p.describe(), contains('被换过'));
    });

    test('**被换过时不许自动重钉** —— 否则一次替换会被就地洗白，下一轮再也看不见', () {
      freshPin();
      _write(imgRel, 'IMAGE-A');
      pinSelfcheckImage(root: kSandbox, codeDigest: 'aaa', codeBinds: true);
      _write(imgRel, 'IMAGE-B');
      pinSelfcheckImage(root: kSandbox, codeDigest: 'aaa', codeBinds: true);
      final SelfcheckPin again = pinSelfcheckImage(root: kSandbox, codeDigest: 'aaa', codeBinds: true);
      expect(again.tampered, isTrue, reason: '第二轮仍须看见同一个替换');
    });

    test('内容变了 + 代码也变了 + 产出绑得上 → 属重跑产物，重钉，不判违规', () {
      freshPin();
      _write(imgRel, 'IMAGE-A');
      pinSelfcheckImage(root: kSandbox, codeDigest: 'aaa', codeBinds: true);
      _write(imgRel, 'IMAGE-B');
      final SelfcheckPin p = pinSelfcheckImage(root: kSandbox, codeDigest: 'bbb', codeBinds: true);
      expect(p.changed, isTrue);
      expect(p.tampered, isFalse);
      final SelfcheckPin again = pinSelfcheckImage(root: kSandbox, codeDigest: 'bbb', codeBinds: true);
      expect(again.changed, isFalse, reason: '重跑产物应已重钉');
    });

    test('内容没变而代码变了 → 代码摘要要前移，否则连续变动期间的替换会整段漏掉', () {
      // 这是上面那条规则的一个**反直觉但必要**的分支。
      // 若钉永远停在最老那版代码上，那么「代码 X 产的内容 A」与「代码 Y 产的内容 B」
      // 之间的替换，会因为 X≠Y 被判成"重跑产物" —— 于是**恰恰在代码连续变动期间
      // 发生的那次替换，会被整段漏掉**。前移摘要把这个窗口收窄到"最近一轮"。
      freshPin();
      _write(imgRel, 'IMAGE-A');
      pinSelfcheckImage(root: kSandbox, codeDigest: 'aaa', codeBinds: true);

      // 第二轮：内容没变、代码变了 → 摘要应前移到 bbb。
      pinSelfcheckImage(root: kSandbox, codeDigest: 'bbb', codeBinds: true);

      // 第三轮：内容被换、代码保持 bbb（自第二轮起没变）→ 必须判被换过。
      _write(imgRel, 'IMAGE-B');
      final SelfcheckPin p = pinSelfcheckImage(root: kSandbox, codeDigest: 'bbb', codeBinds: true);
      expect(p.tampered, isTrue,
          reason: '摘要不前移的话，这一轮会看到 aaa→bbb 而误判成"重跑产物"');
    });

    test('内容变了 + 代码也变了 + **产出绑不上** → 不重钉（盘上那份属于上一版代码）', () {
      freshPin();
      _write(imgRel, 'IMAGE-A');
      pinSelfcheckImage(root: kSandbox, codeDigest: 'aaa', codeBinds: true);
      _write(imgRel, 'IMAGE-B');
      final SelfcheckPin p = pinSelfcheckImage(root: kSandbox, codeDigest: 'bbb', codeBinds: false);
      expect(p.tampered, isFalse);
      final SelfcheckPin again = pinSelfcheckImage(root: kSandbox, codeDigest: 'bbb', codeBinds: false);
      expect(again.changed, isTrue,
          reason: '绑不上时盘上的标定靶是上一版代码留下的，钉到当前代码摘要上就是就地洗白');
    });

    test('标定靶不存在 → 描述里明说"无法钉住"，不许静默', () {
      freshPin();
      final File f = File('$kSandbox/$imgRel');
      if (f.existsSync()) f.deleteSync();
      final SelfcheckPin p = pinSelfcheckImage(root: kSandbox, codeDigest: 'aaa', codeBinds: true);
      expect(p.fileExists, isFalse);
      expect(p.describe(), contains('无法钉住'));
    });
  });

  group('整轮结论', () {
    test('绑定不成立 → invalidReasons 非空（用于把整轮判为作废）', () {
      _rmSandbox();
      _buildSandbox();
      final Map<String, String> h = _current();
      _writeSummary(blobHashes: h, roundValid: false);
      _writeResidual(h);
      _writeAlphaHoles(h);
      final List<String> r =
          verifyMeasurementOutputs(required: requiredFingerprintPaths(root: kSandbox), current: h, root: kSandbox)
              .where((OutputBinding b) => !b.ok)
              .expand((OutputBinding b) => b.reasons)
              .toList();
      expect(r, isNotEmpty);
    });
  });

  group('报告渲染', () {
    // 渲染只在 `gate_P0.dart` 的 main() 走到最后才发生 —— 那意味着跑一整轮
    // （含 40 分钟的 flutter test）。若它在这里崩了，代价是一整轮白跑。
    test('缺 provenance → 明说"不默认清白"，不是安静地什么都不印', () {
      final String s = provenanceMdSection(null);
      expect(s, contains('无法判定'));
      expect(s, contains('不默认清白'));
    });

    test('绑定成立 / 不成立，两种 toJson() 都能渲染且结论分别写清', () {
      _rmSandbox();
      _buildSandbox();
      final Map<String, String> h = _current();
      _writeSummary(blobHashes: h);
      _writeResidual(h);
      _writeAlphaHoles(h);

      // 直接走真实入口，连 toJson() 一起验。
      final ProvenanceReport rep = provenanceReport(root: kSandbox);
      final String okMd = provenanceMdSection(rep.toJson());
      expect(okMd, contains('绑定成立'));
      expect(okMd, contains('out/P0_compose_summary.json'));
      expect(okMd, contains('标定靶'));

      // 反例：把一份产出打回"不可判"，结论必须翻面。
      _write('out/P0_alpha_holes.json', '{"total": 87}\n');
      final ProvenanceReport bad = provenanceReport(root: kSandbox);
      final String badMd = provenanceMdSection(bad.toJson());
      expect(badMd, contains('绑定不成立'));
      expect(badMd, contains('整轮作废'));
      expect(badMd, isNot(contains('绑定成立')));
    });

    test('指纹域印的是**文件清单**，不只是个数', () {
      // 存在理由：本项目已经栽过两次"数目相等 ≠ 内容相同"——
      // ① `lib` 域两边各按自己的规则枚举，29 vs 101；
      // ② `files` 计数相等而集合不同。
      // 只印个数的检查，第三次还会被同样的方式绕过。
      _rmSandbox();
      _buildSandbox();
      final Map<String, String> h = _current();
      _writeSummary(blobHashes: h);
      _writeResidual(h);
      _writeAlphaHoles(h);

      final List<String> dom = requiredFingerprintPaths(root: kSandbox);
      final ProvenanceReport rep = provenanceReport(root: kSandbox);
      final String md = provenanceMdSection(rep.toJson());

      expect(md, contains('实际域文件清单'), reason: '要有一节专门印清单');
      for (final String p in dom) {
        expect(md, contains(p), reason: '域里的 `$p` 必须在报告里逐行出现');
      }
      // 清单与 toJson 里带的是同一份，不是两处各算各的。
      expect(rep.requiredPaths, dom);
      expect(rep.requiredCount, dom.length,
          reason: '数目与清单必须出自同一处 —— 分两处算就是下一次"数目相等而内容不同"');
      // 不在域里的不许混进来（域被放宽 = 检查形同虚设）。
      expect(md, isNot(contains('lib/readme.md')));
      expect(md, isNot(contains('g01.jpg')));
      expect(md, isNot(contains('__pycache__')));
    });

    test('git 不可用时：域清单仍在、数目不塌成 0（仪表故障 ≠ 样本消失）', () {
      // `currentBlobHashes` 在 git 起不来时返回 null。上一版的 `requiredCount`
      // 是 `currentHashes?.length ?? 0`，于是"取不到哈希"会顺带把"域里有几个文件"
      // 也报成 0——正是本项目反复出现的那个形状：**仪表失败时报告"更少"，而不是
      // "看不到"**。现在数目由域的定义给出，与 git 是否可用无关。
      _rmSandbox();
      _buildSandbox();
      final List<String> dom = requiredFingerprintPaths(root: kSandbox);
      expect(dom, isNotEmpty);
      expect(currentBlobHashes(dom, root: '$kSandbox/__does_not_exist__'), isNull,
          reason: '沙箱不存在的仓库根 → git 必然失败，用来构造"取不到"的情形');
    });
  });
}
