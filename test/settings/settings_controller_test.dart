/// 手动代理开关与缺省地址（用户反馈 2026-09-30）控制器级测试：
/// 缺省值/存量迁移/开关注入摘除/关闭态保存不生效。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipvault/core/app_http.dart' show SystemProxy;
import 'package:clipvault/settings/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SystemProxy.debugReset();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(SystemProxy.debugReset);

  Future<SettingsState> pump(ProviderContainer container) =>
      container.read(settingsControllerProvider.future);

  test('全新安装：开关关、地址为缺省 127.0.0.1:2080、运行时直连', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = await pump(container);
    expect(s.proxyEnabled, isFalse);
    expect(s.proxyAddress, kDefaultProxyAddress);
    expect(s.effectiveProxyAddress, kDefaultProxyAddress);
    expect(SystemProxy.proxySetting, 'DIRECT');
  });

  test('存量迁移：已保存非空地址（无开关键）→ 迁移为开启态并固化到 prefs', () async {
    SharedPreferences.setMockInitialValues({
      kPrefSettingsProxyAddress: '192.168.1.5:8888',
    });
    // ProviderContainer.dispose() 返回 void（Riverpod 3.4）：本用例手工
    // 释放并重建第二容器验证"重启"，故不挂 addTearDown（防双重 dispose）
    final container = ProviderContainer();
    final s = await pump(container);
    expect(s.proxyEnabled, isTrue);
    expect(s.proxyAddress, '192.168.1.5:8888');
    // 迁移结果回写固化（审查发现 #1）：清空地址保存后重启不得翻转为关闭
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kPrefSettingsProxyEnabled), isTrue);

    // 迁移开启 + 清空地址保存 → 重启（新容器）后仍为开启（空地址回落缺省）
    await container
        .read(settingsControllerProvider.notifier)
        .setProxyAddress('');
    container.dispose();
    SystemProxy.debugReset();
    final container2 = ProviderContainer();
    final s2 = await pump(container2);
    expect(s2.proxyEnabled, isTrue);
    expect(s2.proxyAddress, '');
    expect(s2.effectiveProxyAddress, kDefaultProxyAddress);
  });

  test('存量迁移：已保存空串（原跟随系统代理语义）→ 保持关闭、地址空', () async {
    SharedPreferences.setMockInitialValues({
      kPrefSettingsProxyAddress: '',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = await pump(container);
    expect(s.proxyEnabled, isFalse);
    expect(s.proxyAddress, '');
  });

  test('存量空串用户开启开关：落缺省并即时注入；关闭摘除、地址保留', () async {
    SharedPreferences.setMockInitialValues({
      kPrefSettingsProxyAddress: '',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsControllerProvider.notifier);
    await pump(container);

    await notifier.setProxyEnabled(true);
    expect(SystemProxy.proxySetting, 'PROXY 127.0.0.1:2080');
    final on = container.read(settingsControllerProvider).value!;
    expect(on.proxyEnabled, isTrue);
    expect(on.proxyAddress, kDefaultProxyAddress);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kPrefSettingsProxyAddress), kDefaultProxyAddress);
    expect(prefs.getBool(kPrefSettingsProxyEnabled), isTrue);

    await notifier.setProxyEnabled(false);
    expect(SystemProxy.proxySetting, 'DIRECT');
    final off = container.read(settingsControllerProvider).value!;
    expect(off.proxyEnabled, isFalse);
    // 关闭仅摘除注入，地址保留——重开免重填
    expect(off.proxyAddress, kDefaultProxyAddress);
    expect(prefs.getString(kPrefSettingsProxyAddress), kDefaultProxyAddress);
  });

  test('开关关闭时保存地址：持久化但运行时不生效（仍直连）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsControllerProvider.notifier);
    await pump(container);

    final ok = await notifier.setProxyAddress('127.0.0.1:7890');
    expect(ok, isTrue);
    expect(SystemProxy.proxySetting, 'DIRECT');
    final s = container.read(settingsControllerProvider).value!;
    expect(s.proxyAddress, '127.0.0.1:7890');
    expect(s.proxyEnabled, isFalse);

    // 保存过的地址在开启开关时立即生效
    await notifier.setProxyEnabled(true);
    expect(SystemProxy.proxySetting, 'PROXY 127.0.0.1:7890');
  });

  test('开关开启时保存自定义地址：即时生效；空串回落缺省', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsControllerProvider.notifier);
    await pump(container);
    await notifier.setProxyEnabled(true);

    expect(await notifier.setProxyAddress('127.0.0.1:7890'), isTrue);
    expect(SystemProxy.proxySetting, 'PROXY 127.0.0.1:7890');

    // 空串合法：开启态下回落缺省（不注入空地址）
    expect(await notifier.setProxyAddress(''), isTrue);
    expect(SystemProxy.proxySetting, 'PROXY 127.0.0.1:2080');
  });

  test('非法地址：返回 false，状态与注入不变', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsControllerProvider.notifier);
    await pump(container);
    await notifier.setProxyEnabled(true);

    expect(await notifier.setProxyAddress('abc'), isFalse);
    final s = container.read(settingsControllerProvider).value!;
    expect(s.proxyAddress, kDefaultProxyAddress);
    expect(SystemProxy.proxySetting, 'PROXY 127.0.0.1:2080');
  });

  group('自动代理调节总开关（proxyAuto）', () {
    test('全新安装默认开启；不触碰代理解析器', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final s = await pump(container);
      expect(s.proxyAuto, isTrue);
      // 总开关只调节自动行为，不改变当前代理注入状态
      expect(SystemProxy.proxySetting, 'DIRECT');
    });

    test('预置 false 读取关闭；setProxyAuto 落盘且不惊动代理注入', () async {
      SharedPreferences.setMockInitialValues({
        kPrefSettingsProxyAuto: false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(settingsControllerProvider.notifier);
      final s0 = await pump(container);
      expect(s0.proxyAuto, isFalse);

      await notifier.setProxyEnabled(true);
      expect(SystemProxy.proxySetting, 'PROXY 127.0.0.1:2080');

      await notifier.setProxyAuto(true);
      final s1 = container.read(settingsControllerProvider).value!;
      expect(s1.proxyAuto, isTrue);
      // 开关切换不影响已注入的手动代理
      expect(SystemProxy.proxySetting, 'PROXY 127.0.0.1:2080');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kPrefSettingsProxyAuto), isTrue);
    });
  });
}
