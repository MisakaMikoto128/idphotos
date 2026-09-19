# native/android — 补齐 ONNX Runtime 的 x86_64 动态库

## 为什么需要这个目录

pub 包 `onnxruntime: ^1.4.1` 的 `android/src/main/jniLibs/` **只带了
`arm64-v8a` 和 `armeabi-v7a`**，没有 `x86_64`（上游 2023-12 刻意移除）。

后果：真机（全是 arm64）没问题，但本项目的两台 AVD
（`Pixel_3a_API_34_extension_level_7_x86_64` 与 `MuZhao_Small`）都是 x86_64，
安装时系统挑 x86_64 这套 native 库，运行到
`DynamicLibrary.open('libonnxruntime.so')` 就会 `UnsatisfiedLinkError`。
凡是在模拟器上跑的东西——G2A 的设备端评测、G3 端到端、G4 批量回归——
都会在 warmUp 第一步挂掉。

## 这里放了什么

`jniLibs/x86_64/libonnxruntime.so`（38.5 MB）取自 Maven Central 官方包
`com.microsoft.onnxruntime:onnxruntime-android:1.29.0` 的 `jni/x86_64/`，
与 vendored 插件（`native/vendor/onnxruntime_flutter`，见该处 VENDORED.md）
三 ABI 同源同版本。

2026-09-19 提速专项从 1.15.1 换到 1.29.0：插件已改 path 依赖 vendored 版
（自带 x86_64），本目录这份与 vendored 的 x86_64 **字节相同**，gradle
`packaging.jniLibs.pickFirsts` 取哪份都一样。保留本目录是为了
"插件被换回 hosted 时模拟器仍能跑"的兜底。

旧 1.15.1 版留档：`native/vendor/ort-bin/ort-1.15.1-android-x86_64.libonnxruntime.so`。

版本对得上：Dart 绑定按 `GetApi(15)` 取前缀布局，ORT 1.29 实测兼容
（GetApi 支持 [1,29]，append-only 结构体，Python ctypes 与设备端探针
双路验证，探针打印 `ort=1.29.0`）。

## release agent 已做的事（历史记录）

`android/app/build.gradle.kts` 已加 jniLibs.srcDirs 合并本目录，
release 用 abiFilters 排掉 x86/x86_64（模拟器验证走 MUZHAO_EXTRA_ABIS）。

