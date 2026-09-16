# 木照 MuZhao R8/ProGuard keep 规则（release 阶段 5）
#
# 原则：只 keep 走反射/FFI 动态绑定的路径，其余照常混淆。
# 任何新增 keep 必须在 release 全量回归（e2e 出图 + 黄金集冒烟）里验证过。

# --- onnxruntime pub 插件（com.gtbluesky.onnxruntime）---
# 插件 Java 层通过 JNI 回调/MethodChannel + native 层按类名查找，
# R8 剪掉会表现为 warmUp/建会话时 NoSuchMethodError / UnsatisfiedLinkError。
-keep class com.gtbluesky.onnxruntime.** { *; }
-keepclassmembers class com.gtbluesky.onnxruntime.** { *; }

# ONNX Runtime C++ 库经 JNI 注册回调 Java 侧时保留 native 方法名
-keepclasseswithmembernames class * {
    native <methods>;
}
