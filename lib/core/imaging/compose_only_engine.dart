/// 木照 MuZhao — 只做合成的引擎实例。
///
/// [ComposeEngineMixin] 声明 `implements IdPhotoEngine`，单独使用时需要一个
/// 落地类。本类把抠图/检脸三个方法按契约实现成「本引擎不提供该能力」，
/// 供以下两种场景使用：
///
/// - imaging 自检（`dev_selfcheck.dart`）：直接喂现成的 [MattingResult]，
///   不需要 ONNX 模型；
/// - ui-woodcraft 的 `FakeController` / 主会话阶段 3 接线前的临时调用。
///
/// 阶段 3 主会话会把 [ComposeEngineMixin] 与 ml-porting 的
/// `MattingEngineMixin` 合成成真正的 `IdPhotoEngineImpl`，本类不参与发布路径。
library;

import 'dart:typed_data';

import '../api.dart';
import 'compose_engine.dart';

/// 只实现 [IdPhotoEngine.compose] 的引擎。
class ComposeOnlyEngine with ComposeEngineMixin {
  @override
  Future<void> warmUp() async {
    // 合成不需要任何模型，预热是空操作（契约要求幂等）。
  }

  @override
  Future<MattingResult> removeBackground(Uint8List imageBytes) async {
    // 本引擎不含抠图能力，按错误契约返回中文文案而不是崩溃。
    throw const MattingException(cause: 'ComposeOnlyEngine 不提供抠图能力');
  }

  @override
  Future<FaceInfo?> detectFace(Uint8List imageBytes) async {
    // 契约规定「无人脸返回 null，不抛异常」；本引擎恒无检测能力。
    return null;
  }

  @override
  void dispose() {
    // 无 native 资源可释放。
  }
}
