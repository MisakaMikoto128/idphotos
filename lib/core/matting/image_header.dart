/// 从字节流的文件头**同步**读出图片像素尺寸（含 EXIF orientation 修正）。
///
/// 实现（simplify 起）上移到 `lib/core/image_header.dart`（两份逐行双写的
/// 拷贝合并为一份，见该文件文档）。本文件只做 re-export，保住既有
/// `package:muzhao/core/matting/image_header.dart` 的 import 路径
/// （`image_ops.dart` 与 native/bench 的头扫描测试都从这里引）。
library;

export '../image_header.dart';
