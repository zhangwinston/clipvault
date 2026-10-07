/// 自动代理调节 Riverpod 适配层测试：
/// read() 字段映射（含未加载 fail-closed）/ autoEnable·autoDisable 组合
/// 写路径（prefs 落盘 + SystemProxy 即时注入）/ 协调器 Provider 装配冒烟。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clipvault/core/app_http.dart' show SystemProxy;
import 'package:clipvault/settings/proxy_auto_provider.dart';
import 'package:clipvault/settings/settings_controller.dart';

/// 捕获 Ref 的测试 Provider（Provider build 参数即 Ref）。
final Provider<Ref> refCaptureProvider = Provider<Ref>((ref) => ref);

void main() {
  setUp(() {
    SystemProxy.debugReset();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(SystemProxy.debugReset);

  test('read()：字段映射与 effectiveProxyAddress 缺省回落', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsControllerProvider.future);

    final s = RiverpodProxyAutoSettings(container.read(refCaptureProvider));
    final view = s.read();
    expect(view.autoEnabled, isTrue); // proxyAuto 默认开
    expect(view.proxyEnabled, isFalse);
    expect(view.effectiveProxyAddress, kDefaultProxyAddress); // 空地址回落缺省
  });

  test('read()：设置未加载（启动竞态窗口）→ autoEnabled fail-closed', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 不 await settings future：AsyncLoading，value 为 null
    final s = RiverpodProxyAutoSettings(container.read(refCaptureProvider));
    expect(s.read().autoEnabled, isFalse);
  });

  test('autoEnable：地址落盘 + 开关置开 + SystemProxy 即时注入', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsControllerProvider.future);

    final s = RiverpodProxyAutoSettings(container.read(refCaptureProvider));
    await s.autoEnable('127.0.0.1:7890');

    expect(SystemProxy.proxySetting, 'PROXY 127.0.0.1:7890');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kPrefSettingsProxyAddress), '127.0.0.1:7890');
    expect(prefs.getBool(kPrefSettingsProxyEnabled), isTrue);
    final state = container.read(settingsControllerProvider).value!;
    expect(state.proxyEnabled, isTrue);
    expect(state.proxyAddress, '127.0.0.1:7890');
  });

  test('autoDisable：仅关开关（地址保留）+ SystemProxy 摘除', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsControllerProvider.notifier);
    await container.read(settingsControllerProvider.future);
    await notifier.setProxyAddress('127.0.0.1:7890');
    await notifier.setProxyEnabled(true);
    expect(SystemProxy.proxySetting, 'PROXY 127.0.0.1:7890');

    final s = RiverpodProxyAutoSettings(container.read(refCaptureProvider));
    await s.autoDisable();

    expect(SystemProxy.proxySetting, 'DIRECT');
    final state = container.read(settingsControllerProvider).value!;
    expect(state.proxyEnabled, isFalse);
    expect(state.proxyAddress, '127.0.0.1:7890'); // 地址保留，重开免重填
  });

  test('协调器 Provider 装配冒烟：可实例化；用户手动改设置不惊动装配',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsControllerProvider.future);

    final coordinator = container.read(proxyAutoCoordinatorProvider);
    expect(coordinator.events, isNotNull);

    // 用户手动改代理开关（gate 外变化）：设置差分监听路径执行不抛，
    // 设置状态正常更新（markUserTouched 为内部防抖解除，无外部可观测
    // 副作用——行为级断言在 proxy_auto_test 的稳定期用例覆盖）
    final notifier = container.read(settingsControllerProvider.notifier);
    await notifier.setProxyEnabled(true);
    expect(
        container.read(settingsControllerProvider).value!.proxyEnabled, isTrue);
  });
}
