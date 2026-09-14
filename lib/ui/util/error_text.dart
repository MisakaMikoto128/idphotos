/// 异常 → 用户可见的中文提示。
///
/// CONTRACTS §6 规定引擎异常由 controller 层转成 `AppState.errorMessage`，
/// 不得穿透到 UI。但有两条路径**不经过 controller**，必须由 UI 自己兜底：
///
/// * 取图：`ImagePicker` 在用户拒绝 `READ_MEDIA_IMAGES`、picker activity 被
///   系统回收、插件未注册时抛 `PlatformException` / `MissingPluginException`；
/// * 保存：`IdPhotoController.save()` 返回的 Future 可能 reject（无存储权限、
///   磁盘满、MediaStore 插入失败）。异常若从 `VoidCallback` 逃逸成未处理的
///   异步错误，按钮的 busy 标志永远复位不了，用户不重启 App 就没法重试。
///
/// 这里**不吞异常** —— 每一条都转成一句用户看得懂的中文，交给界面显示出来；
/// 同时用 `debugPrint` 把原始异常留在日志里，方便定位。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';

/// 把任意异常翻成一句中文。永远返回非空字符串。
String errorTextOf(Object error, {required String fallback}) {
  // 引擎自己的异常已经带好文案（CONTRACTS §6 的四条）
  if (error is IdPhotoException) return error.messageZh;

  if (error is MissingPluginException) {
    return '这台设备打不开相册';
  }

  if (error is PlatformException) {
    switch (error.code) {
      case 'photo_access_denied':
      case 'camera_access_denied':
        return '没有相册权限，请到系统设置里允许访问照片';
      case 'already_active':
        return '正在选择照片，请稍等一下';
      case 'invalid_image':
        return '这个图片格式打不开';
      case 'multiple_request':
        return '正在选择照片，请稍等一下';
    }
    return fallback;
  }

  return fallback;
}

/// 统一的日志出口：保留原始异常与栈，界面上只给用户看翻译后的中文。
void logUiError(String where, Object error, StackTrace stack) {
  debugPrint('MuZhao/UI $where: $error');
  debugPrintStack(stackTrace: stack, maxFrames: 8);
}
