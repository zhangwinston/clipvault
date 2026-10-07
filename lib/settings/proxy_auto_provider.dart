/// 自动代理调节的 Riverpod 装配层（DESIGN §6.9「双向自动调节」）。
///
/// 把 [ProxyAutoCoordinator]（core 纯逻辑）与 SettingsController /
/// connectivity_plus 缝合：
/// - 设置读写：[RiverpodProxyAutoSettings]——autoEnable/autoDisable 组合
///   SettingsController 既有公共写路径（各自内部 `_serialized` 串行），
///   自动切换因此与手动操作同一持久化语义（设置页可见、重启保持）；
/// - 用户意图差分：[_AutoWriteGate] 标记协调器自动写入进行中，配合
///   `ref.listen` ——gate 之外的 proxyEnabled/proxyAddress 变化即用户
///   手动改设置 → `markUserTouched()` 立即解除稳定期；
/// - Wi-Fi 判定：内联 connectivity_plus（3 行）而非复用 ui 层的
///   ConnectivityChecker——避免 settings → ui(task_tile) 反向依赖。
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:clipvault/core/proxy_auto.dart';
import 'package:clipvault/settings/settings_controller.dart';

/// 自动写入进行中标记：state 赋值在 autoEnable/autoDisable 的 await 链
/// 内同步发生，标志位可靠覆盖该窗口。装配层的设置差分监听共用同一实例
/// 区分「协调器自动写入」与「用户手动改设置」。
class AutoWriteGate {
  bool inFlight = false;

  Future<T> around<T>(Future<T> Function() fn) async {
    inFlight = true;
    try {
      return await fn();
    } finally {
      inFlight = false;
    }
  }
}

/// [ProxyAutoSettings] 的 Riverpod 适配。
class RiverpodProxyAutoSettings implements ProxyAutoSettings {
  RiverpodProxyAutoSettings(this._ref, {AutoWriteGate? gate})
      : gate = gate ?? AutoWriteGate();

  final Ref _ref;

  /// 自动写入门闩（装配层差分监听读 inFlight；测试可直接构造本类）。
  final AutoWriteGate gate;

  @override
  ProxyAutoSettingsView read() {
    final s = _ref.read(settingsControllerProvider).value;
    // 设置未加载（启动竞态窗口）：autoEnabled 按 false 处理（fail-closed）
    // ——自动行为宁可不发生，也不在用户偏好未知时动代理。
    if (s == null) {
      return const ProxyAutoSettingsView(
        autoEnabled: false,
        proxyEnabled: false,
        effectiveProxyAddress: kDefaultProxyAddress,
      );
    }
    return ProxyAutoSettingsView(
      autoEnabled: s.proxyAuto,
      proxyEnabled: s.proxyEnabled,
      effectiveProxyAddress: s.effectiveProxyAddress,
    );
  }

  @override
  Future<void> autoEnable(String address) => gate.around(() async {
        final notifier = _ref.read(settingsControllerProvider.notifier);
        // 组合既有公共写路径：两步序列（先地址后开关）无 broken 中间态
        //（地址先存、开关未变仍直连），各步内部 `_serialized` 与用户
        // 手动写互斥，无丢更新窗口。
        if (!await notifier.setProxyAddress(address)) {
          return; // 探测产出的地址已归一化，理论不可达；防御性容忍
        }
        await notifier.setProxyEnabled(true);
      });

  @override
  Future<void> autoDisable() => gate.around(() async {
        await _ref
            .read(settingsControllerProvider.notifier)
            .setProxyEnabled(false);
      });
}

/// 协调器装配点：应用级单例，engine/commands/parse/app 四侧经
/// `ref.read(proxyAutoCoordinatorProvider)` 取用。
final Provider<ProxyAutoCoordinator> proxyAutoCoordinatorProvider =
    Provider<ProxyAutoCoordinator>((ref) {
  final settings = RiverpodProxyAutoSettings(ref);
  final coordinator = ProxyAutoCoordinator(
    settings: settings,
    now: DateTime.now,
    // fail-closed：判定异常按非 Wi-Fi（方向 B 是「关代理」的破坏性动作，
    // 必须保守；与下载侧 onWifiProvider 的 fail-open 语义有意相反）。
    isOnWifi: () async {
      try {
        final results = await Connectivity().checkConnectivity();
        return results.contains(ConnectivityResult.wifi);
      } catch (_) {
        return false;
      }
    },
  );
  // 用户手动改代理设置（gate 外的开关/地址变化）→ 稳定期立即解除。
  // fireImmediately 默认 false：首值不算 user touch。
  ref.listen(settingsControllerProvider, (previous, next) {
    final prev = previous?.value;
    final cur = next.value;
    if (prev == null || cur == null || settings.gate.inFlight) return;
    if (prev.proxyEnabled != cur.proxyEnabled ||
        prev.proxyAddress != cur.proxyAddress) {
      coordinator.markUserTouched();
    }
  });
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
