# native/android — 补齐 ONNX Runtime 的 x86_64 动态库

## 为什么需要这个目录

pub 包 `onnxruntime: ^1.4.1` 的 `android/src/main/jniLibs/` **只带了
`arm64-v8a` 和 `armeabi-v7a`**，没有 `x86_64`。

后果：真机（全是 arm64）没问题，但本项目的两台 AVD
（`Pixel_3a_API_34_extension_level_7_x86_64` 与 `MuZhao_Small`）都是 x86_64，
安装时系统挑 x86_64 这套 native 库，运行到
`DynamicLibrary.open('libonnxruntime.so')` 就会 `UnsatisfiedLinkError`。
凡是在模拟器上跑的东西——G2A 的设备端评测、G3 端到端、G4 批量回归——
都会在 warmUp 第一步挂掉。

## 这里放了什么

`jniLibs/x86_64/libonnxruntime.so`（16.5 MB）取自 Maven Central 官方包
`com.microsoft.onnxruntime:onnxruntime-android:1.15.1` 的 `jni/x86_64/`。

版本对得上：该 AAR 里 `jni/arm64-v8a/libonnxruntime.so` 与插件自带的那份
字节数完全一致（14,203,224），说明插件就是从这个 AAR 重打包出来的，
两者 ABI/API 版本相同（`OrtGetApiBase()->GetApi(14)`）。

## 需要 release agent 做的事

`android/app/build.gradle.kts` 不归 ml-porting，请在 `android { }` 里加：

```kotlin
sourceSets {
    getByName("main") {
        jniLibs.srcDirs("src/main/jniLibs", "../../native/android/jniLibs")
    }
}
```

发布包不需要 x86_64（真机没有 x86_64 Android 手机），用 abiFilters 排掉即可，
详见 ml-porting 阶段 2 报告里给 release 的完整清单。
