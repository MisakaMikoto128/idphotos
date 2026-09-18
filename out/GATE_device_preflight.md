# 设备预检 —— 2026-09-17T17:12:13.210065

主机：windows / XIAOYUAN

> 这份文件是**入库证据**：`.gitignore` 全局忽略 `*.log`，所以证据写成 `.md`。

== 预检前的 adb devices -l ==
  List of devices attached
  5bc6e093               device product:PD1728 model:vivo_X21A device:PD1728 transport_id:29
  emulator-5554          device product:sdk_gphone64_x86_64 model:sdk_gphone64_x86_64 device:emu64xa transport_id:31

== requireEmulatorDevice（只认 emulator-*，拿不到就抛）==

== 判据 1：真机在线时被选中的是谁 ==
  当前在线的真机（应被无视）：5bc6e093
  requireEmulatorDevice 返回：emulator-5554
  PASS —— 选中的是模拟器

== 判据 2：这台模拟器真的能用吗 ==
  sys.boot_completed = 1（期望 1）
  wm size            = Physical size: 1080x2220
  ro.build.characteristics = emulator（期望含 emulator）
  PASS

== 判据 3：内存是否 4096（CLAUDE.md 硬要求；否则 G4.6/4.7 是假数字）==
  MemTotal = 4015652 kB ≈ 3.83 GB（4096MB 的 AVD 实测约 3.83GB，内核占一部分）
  PASS

## 结论：**预检 PASS** —— 模拟器可用（emulator-5554），真机被正确忽略，内存 4096。
