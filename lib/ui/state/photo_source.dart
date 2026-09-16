/// 相册取图。
///
/// `IdPhotoController.loadImage(Uint8List)` 只接收字节，**从哪儿拿字节是 UI 的事**。
/// 这里把它抽成一个可替换的服务，好处有二：
/// * 截图/测试场景可以覆盖成"直接返回内置样张"，不弹系统相册；
/// * 阶段 3 主会话接线时如果要换成别的取图方式，只需覆盖这个 Provider。
///
/// 全程本地：只读取用户主动选中的那一张，不上传、不缓存到 App 外部目录。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:typed_data';

import 'dart:io' show Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

abstract class PhotoSource {
  /// 返回 null 表示用户取消。
  Future<Uint8List?> pick();
}

/// 系统相册（Android/iOS）。
class GalleryPhotoSource implements PhotoSource {
  const GalleryPhotoSource();

  @override
  Future<Uint8List?> pick() async {
    final XFile? file =
        await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return null;
    return file.readAsBytes();
  }
}

/// 桌面端文件选择（Windows 等——无系统"相册"概念，走打开文件对话框）。
class DesktopPhotoSource implements PhotoSource {
  const DesktopPhotoSource();

  @override
  Future<Uint8List?> pick() async {
    final XTypeGroup group = const XTypeGroup(
      label: '图片',
      extensions: <String>['jpg', 'jpeg', 'png', 'webp', 'bmp'],
    );
    final XFile? file =
        await openFile(acceptedTypeGroups: <XTypeGroup>[group]);
    if (file == null) return null;
    return file.readAsBytes();
  }
}

final Provider<PhotoSource> photoSourceProvider = Provider<PhotoSource>((Ref ref) {
  if (!kIsWeb && Platform.isWindows) return const DesktopPhotoSource();
  return const GalleryPhotoSource();
});
