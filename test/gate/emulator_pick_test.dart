// test/gate/emulator_pick_test.dart
//
// **"只认 emulator-*"这条规则的守卫。**
//
// 存在理由：2026-09-17，主机上唯一的 adb 设备是**用户真机 vivo X21A**（`5bc6e093`）。
// 当时 `gate_common.dart` 里有一个公开入口，它返回 `adb devices` 里第一个 `device`
// 态设备、**不看前缀**，取不到就返回 null（该入口现已**整个删除**）。于是
// `gate_G2B.dart:91` / `gate_G2A.dart:157` 的"先问它要设备，要不到再启动模拟器"
// 里那个空值合并 **`??` 右侧被短路** ——
// 模拟器**根本不会启动**，`flutter drive` 直接把 APK 装向真机。
// 真机拒绝无人值守安装（`Failure [-200]`），三轮各 ~191s 撞穿 G2B 的 10 分钟预算，
// 产出 9/9 `pass=false, manual=false, timedOut=true` ——
// **与"真的 9 项退化"完全同形**。门禁会拿它报出 9 条不存在的退化。
//
// 教训：规则写在 `docs/PITFALLS.md:421`，G4 在 r2 补了，G2A/G2B 没补 ⇒
// **一份规则、两处实现**。现在实现收敛到 `gate_common.requireEmulatorDevice` 一处，
// 选择逻辑抽成纯函数 `emulatorSerialInLine`，本文件就是它的正负控制。
//
// **每条断言都必须能在"该红"的地方红**：尤其"真机行必须返回 null"这条 ——
// 只要它退回真机，上面那 9 条假退化就会重现。
//
// 属 gatekeeper 势力范围（test/gate/）。
// 运行：`flutter test test/gate/emulator_pick_test.dart`

// flutter_test 是 dev_dependency。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';

import '../../tools/gate/gate_common.dart';

/// 把一段完整的 `adb devices` 输出按行喂进去，返回**被选中的**那台（模拟首次命中）。
/// 与 `requireEmulatorDevice` 内部的挑选口径一致。
String? pickFrom(String adbDevicesOutput) {
  for (final String line in adbDevicesOutput.split('\n')) {
    final String? id = emulatorSerialInLine(line);
    if (id != null) return id;
  }
  return null;
}

void main() {
  group('emulatorSerialInLine：只认 emulator-*', () {
    test('在线的模拟器 ⇒ 返回 serial', () {
      expect(emulatorSerialInLine('emulator-5554\tdevice'), 'emulator-5554');
    });

    test('**在线的真机 ⇒ null**（这条就是本次事故本身）', () {
      // 真机状态是 `device`、调试授权正常、型号完好 —— 但绝不许被选中。
      expect(emulatorSerialInLine('5bc6e093\tdevice'), isNull);
      expect(emulatorSerialInLine('1e01895d\tdevice'), isNull);
      expect(emulatorSerialInLine('PD1728\tdevice'), isNull);
    });

    test('前缀才算数：serial 里含 emulator- 但不在开头 ⇒ null', () {
      expect(emulatorSerialInLine('notemulator-5554\tdevice'), isNull);
      expect(emulatorSerialInLine('x-emulator-5554\tdevice'), isNull);
    });

    test('模拟器非 device 态（offline / unauthorized）⇒ null', () {
      expect(emulatorSerialInLine('emulator-5554\toffline'), isNull);
      expect(emulatorSerialInLine('emulator-5554\tunauthorized'), isNull);
      expect(emulatorSerialInLine('emulator-5554\tno permissions'), isNull);
    });

    test('`adb devices -l` 长格式 ⇒ 仍能取到', () {
      expect(
        emulatorSerialInLine(
            'emulator-5554          device product:sdk_gphone64_x86_64 model:sdk_gphone64_x86_64 device:emu64x transport_id:3'),
        'emulator-5554',
      );
    });

    test('Windows 的 \\r 不影响（CRLF 换行）', () {
      expect(emulatorSerialInLine('emulator-5554\tdevice\r'), 'emulator-5554');
    });

    test('表头 / 空行 / 守护进程横幅 ⇒ null', () {
      expect(emulatorSerialInLine('List of devices attached'), isNull);
      expect(emulatorSerialInLine(''), isNull);
      expect(emulatorSerialInLine('   '), isNull);
      expect(
        emulatorSerialInLine('* daemon not running; starting now at tcp:5037'),
        isNull,
      );
      expect(emulatorSerialInLine('* daemon started successfully'), isNull);
    });

    test('单字段行（没有状态列）⇒ null', () {
      expect(emulatorSerialInLine('emulator-5554'), isNull);
    });
  });

  group('整段 adb devices 输出的挑选', () {
    test('只有真机在线 ⇒ 谁都不选（绝不能退回真机）', () {
      expect(pickFrom('List of devices attached\n5bc6e093\tdevice\n'), isNull);
    });

    test('真机 + 模拟器同时在线 ⇒ 选模拟器', () {
      expect(
        pickFrom('List of devices attached\n5bc6e093\tdevice\nemulator-5554\tdevice\n'),
        'emulator-5554',
      );
    });

    test('模拟器排在真机前面 ⇒ 选模拟器（两个方向都试）', () {
      expect(
        pickFrom('List of devices attached\nemulator-5554\tdevice\n5bc6e093\tdevice\n'),
        'emulator-5554',
      );
    });

    test('空输出（无任何设备）⇒ 谁都不选', () {
      expect(pickFrom('List of devices attached\n\n'), isNull);
    });

    test('反面控制：真机 + 模拟器 offline ⇒ 谁都不选', () {
      // 模拟器在但不可用，此时**不许**退而求其次抓真机。
      expect(
        pickFrom('List of devices attached\n5bc6e093\tdevice\nemulator-5554\toffline\n'),
        isNull,
      );
    });
  });
}
