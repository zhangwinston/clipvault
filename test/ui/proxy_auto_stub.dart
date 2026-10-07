/// widget 测试通用的零操作自动代理协调器 override（§6.9 自动调节）。
///
/// 用途：凡会触发解析/下载的 widget 测试，把 [noopProxyAutoOverrides]
/// 展开进 ProviderScope.overrides——解析入口的 preflight/失败兜底秒回，
/// 隔离真实探测与本机代理端口；真实协调器的 connectivity_plus 通道在
/// FakeAsync 测试环境无平台实现，await 永不返回会卡死解析链。
library;

import 'package:clipvault/core/proxy_auto.dart';
import 'package:clipvault/settings/proxy_auto_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class _NoopAutoSettings implements ProxyAutoSettings {
  const _NoopAutoSettings();

  @override
  ProxyAutoSettingsView read() => const ProxyAutoSettingsView(
        autoEnabled: false,
        proxyEnabled: false,
        effectiveProxyAddress: '127.0.0.1:2080',
      );

  @override
  Future<void> autoEnable(String address) async {}

  @override
  Future<void> autoDisable() async {}
}

/// 展开进 overrides：`...noopProxyAutoOverrides,`
final List<Override> noopProxyAutoOverrides = <Override>[
  proxyAutoCoordinatorProvider.overrideWith(
    (ref) => ProxyAutoCoordinator(
      settings: const _NoopAutoSettings(),
      now: DateTime.now,
    ),
  ),
];
