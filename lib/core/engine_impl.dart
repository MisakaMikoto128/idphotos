/// 木照 MuZhao — 引擎实现（接线层）。
///
/// 主会话在阶段 3 把两个并行交付的 mixin 合成为 [IdPhotoEngine] 的唯一实现：
///
/// - `MattingEngineMixin`（ml-porting）：[IdPhotoEngine.warmUp] /
///   [IdPhotoEngine.removeBackground] / [IdPhotoEngine.detectFace]
/// - `ComposeEngineMixin`（imaging）：[IdPhotoEngine.compose]，
///   以及自动裁剪推算 `suggestedCropInSourcePx`
///
/// 势力范围：主会话（CLAUDE.md §4 接线层）。本文件只做组合，**不写业务逻辑** ——
/// 两个 mixin 各自的领域问题（推理、几何）分别在 `lib/core/matting/` 与
/// `lib/core/imaging/` 里解决。
library;

import 'api.dart';
import 'imaging/compose_engine.dart';
import 'matting/matting_engine.dart';

/// 组合两个 mixin。mixin 顺序即抽象成员解析顺序；
/// 两者没有同名成员，顺序无实际影响，但保持与契约文档一致的书写顺序。
class IdPhotoEngineImpl
    with MattingEngineMixin, ComposeEngineMixin
    implements IdPhotoEngine {
  @override
  void dispose() => disposeMattingEngine();
}
