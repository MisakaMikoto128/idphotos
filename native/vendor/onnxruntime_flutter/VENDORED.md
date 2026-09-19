# Vendored onnxruntime_flutter 1.4.1 + ORT 1.29.0 二进制

来源：pub.dev `onnxruntime` 1.4.1（gtbluesky/onnxruntime_flutter，2024-03-27，
pub.dev 与上游 main 均停在 ORT 1.15.1 捆绑件，无更新版本可用）。

改动（相对 pub 版）：
- `windows/onnxruntime.dll`：替换为官方 onnxruntime-win-x64-1.29.0.zip 的 dll
  （16,149,344 字节，含 XNNPACK；pub 版的 1.15.1 dll 为 CPU-only 精简构建）。
- `android/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libonnxruntime.so`：
  替换为官方 onnxruntime-android 1.29.0 AAR 的 .so；x86_64 为新增
  （pub 版 2023-12 起刻意移除了 x86/x86_64）。
- Dart 代码零改动：插件按 `GetApi(15)` 取 OrtApi 前缀布局，ORT 1.29 实测
  兼容（GetApi 支持 [1,29]，同指针返回，append-only 结构体）。
- 未替换：ios/macos/linux 目录的 1.15.1 二进制（本项目不构建这些平台）。

二进制原件与校验：`native/vendor/ort-bin/`（zip/aar 原包留档）。
配套注意：启用后 `native/android/jniLibs/x86_64`（ORT 1.15.1）与本插件的
x86_64 .so 撞名，pickFirst 只留一份——届时删除 native/android/jniLibs。
