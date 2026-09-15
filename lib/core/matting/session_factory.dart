/// ORT 会话工厂：一个进程生命周期级的常驻 isolate，专职创建会话。
///
/// 为什么会话创建必须住进常驻 isolate（REVIEW_G3 X5/B1）：插件的
/// `OrtEnv.instance` 是 **per-isolate** 的 Dart 单例，`OrtSession.fromBuffer`
/// 内部会走到 `OrtEnv.instance.ptr`，而它是懒初始化的——第一次访问就
/// `CreateEnv`。如果把会话创建放进随用随弃的 `Isolate.run`，每次
/// `_loadModels`（含 warmUp 失败重试）都会在一个即将消亡的 isolate 里
/// CreateEnv 一次；isolate 退出后 Dart 侧包装对象被 GC，native env 却
/// 没有任何句柄能再释放它。把创建动作固定在一个**不消亡**的 isolate 里，
/// "每进程一个 env"的不变式重新成立，且这个 isolate 消亡时（dispose）
/// 还能显式 `ReleaseEnv`，连最后一次泄漏都堵上。
///
/// 推理不经这里：`OrtSession.fromAddress` / `OrtRunOptions` / 张量创建
/// 只用 OrtApi 句柄，不触 env（源码核对过 ort_session.dart / ort_value.dart），
/// 所以 `Isolate.run` 里跑推理不会偷偷新建环境。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:onnxruntime/onnxruntime.dart'
    show OrtEnv, OrtLoggingLevel;

import 'ort_runtime.dart';

/// 会话创建请求的回执。成功时 [error] 为 null。
class SessionFactoryResult {
  SessionFactoryResult(this.address, this.provider, this.envAddress, this.error);

  /// native session 指针地址；失败时为 0。
  final int address;
  final String provider;

  /// 创建该会话的 OrtEnv 指针地址。同进程内所有会话的此值必须相同——
  /// 这是"每进程一个 env"的可验证不变式（bench 里逐轮断言）。
  final int envAddress;

  final String? error;

  bool get ok => error == null;
}

class SessionFactory {
  Isolate? _isolate;
  Future<SendPort>? _port;
  int? _envAddress;

  /// 全部会话共同的 OrtEnv 地址；一个会话都没建过时为 null。
  int? get envAddress => _envAddress;

  Future<SendPort> _ensurePort() {
    return _port ??= _spawn();
  }

  Future<SendPort> _spawn() async {
    final completer = Completer<SendPort>();
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_factoryMain, ready.sendPort);
    _isolate = isolate;
    SendPort? send;
    final subscription = ready.listen(
      (msg) {
        if (msg is SendPort && !completer.isCompleted) {
          completer.complete(msg);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        // 工厂意外退出：作废端口缓存，下次调用重新孵化。
        _port = null;
        _isolate = null;
        _envAddress = null;
        if (!completer.isCompleted) {
          completer.completeError(const SessionFactoryDeadException());
        }
      },
    );
    send = await completer.future;
    subscription.cancel(); // 只需要握手，之后由请求自带的 ReceivePort 回传
    ready.close();
    return send;
  }

  /// 在工厂 isolate 里创建会话。
  Future<SessionFactoryResult> createSessionInFactory(
    String modelPath, {
    int threads = 4,
  }) async {
    try {
      final send = await _ensurePort();
      final reply = ReceivePort();
      send.send(<Object>[reply.sendPort, modelPath, threads]);
      final msg = await reply.first as List<dynamic>;
      reply.close();
      final result = SessionFactoryResult(
        msg[0] as int,
        msg[1] as String,
        msg[2] as int,
        msg[3] == null ? null : msg[3] as String,
      );
      // env 地址在成功与失败两条路径上都记账：worker 里 env 单例第一次被
      // 触碰（哪怕是失败的 fromBuffer）就会诞生，把失败轮的地址也记下来，
      // "重试不新增 env"才可验证。
      final env = result.envAddress;
      final known = _envAddress;
      if (env != 0) {
        if (known == null) {
          _envAddress = env;
        } else if (known != env) {
          // 理论不可达：工厂 isolate 里 env 单例只会初始化一次。
          return SessionFactoryResult(0, '', env, 'env address changed');
        }
      }
      return result;
    } on SessionFactoryDeadException {
      rethrow;
    } catch (e) {
      return SessionFactoryResult(0, '', 0, e.toString());
    }
  }

  /// 关闭工厂：先通知 worker 显式 ReleaseEnv 再退出，native env 不留悬空。
  Future<void> dispose() async {
    final port = _port;
    final isolate = _isolate;
    _port = null;
    _isolate = null;
    _envAddress = null;
    if (port == null && isolate == null) return;
    try {
      final send = await port;
      final done = ReceivePort();
      send!.send(<Object>[done.sendPort]);
      // worker 回执后自行 Isolate.exit；等不到就强杀（模型创建失败的
      // worker 可能已经死了，属于正常路径）。
      await done.first.timeout(const Duration(seconds: 5), onTimeout: () {});
      done.close();
    } catch (_) {
      // 工厂已死或从未握手成功：无事可做。
    }
    isolate?.kill(priority: Isolate.immediate);
  }
}

/// 工厂 isolate 意外退出。
class SessionFactoryDeadException implements Exception {
  const SessionFactoryDeadException();

  @override
  String toString() => 'session factory isolate died';
}

/// 工厂 isolate 的入口。
///
/// env 的创建走 [createSession] → `OrtSession.fromBuffer` 的懒初始化，
/// 只会发生一次：这个 isolate 活多久，env 就只存在一份。
Future<void> _factoryMain(SendPort ready) async {
  final port = ReceivePort();
  ready.send(port.sendPort);
  // env 在工厂启动时**显式**创建，生命周期与工厂一致；此后 createSession
  // 内部的 _ensureEnv 成为幂等空操作，成功/失败两条路径都能如实上报
  // 同一个 env 地址（"每进程一个 env"可被 bench 逐轮断言）。
  OrtEnv.instance.init(level: OrtLoggingLevel.error);
  await for (final msg in port) {
    final req = msg as List<dynamic>;
    final reply = req[0] as SendPort;
    if (req.length == 1) {
      // dispose 请求：此刻所有会话都已被宿主释放，ReleaseEnv 是安全的。
      OrtEnv.instance.release();
      reply.send(const <Object?>['bye']);
      port.close();
      return;
    }
    try {
      final h = createSession(req[1] as String, threads: req[2] as int);
      reply.send(<Object?>[
        h.address,
        h.provider,
        OrtEnv.instance.ptr.address,
        null,
      ]);
    } catch (e) {
      // 只传字符串：异常对象可能不可跨 isolate 序列化。
      reply.send(<Object?>[0, '', OrtEnv.instance.ptr.address, e.toString()]);
    }
  }
}
