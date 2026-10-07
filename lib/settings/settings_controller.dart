/// 设置控制器：免责声明版本化（§8.3）+ P0/P2 偏好 + 缓存清理策略（§4.6）。
///
/// - 偏好落 shared_preferences，键名严格按 DESIGN §5.4；
/// - [SharedPreferences] 在测试中经 `SharedPreferences.setMockInitialValues` 离线注入；
/// - 缓存统计/清理经 [CacheStore] 抽象注入（生产由 app.dart 绑定仓库实现）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:clipvault/core/app_http.dart'
    show SystemProxy, parseProxyAddress;
import 'package:shared_preferences/shared_preferences.dart';

/// 当前免责条款版本（条款更新时递增，触发重新弹窗，DESIGN §8.3）
const int kCurrentDisclaimerVersion = 1;

// ---- 偏好键（DESIGN §5.4）----
const String kPrefDisclaimerVersion = 'disclaimer.version';
const String kPrefDisclaimerAcceptedAt = 'disclaimer.acceptedAt';
const String kPrefEndpointConfigVersion = 'endpoint.configVersion';
const String kPrefSettingsConcurrency = 'settings.concurrency';
const String kPrefSettingsQualityMode = 'settings.qualityMode';
const String kPrefSettingsWifiOnly = 'settings.wifiOnly';
const String kPrefSettingsBackupHistory = 'settings.backupHistory';
const String kPrefSettingsProxyAddress = 'settings.proxyAddress';
const String kPrefSettingsProxyEnabled = 'settings.proxyEnabled';
const String kPrefSettingsProxyAuto = 'settings.proxyAuto';
const String kPrefSettingsAutoCleanDays = 'settings.autoCleanDays';
const String kPrefSettingsAutoCleanMaxBytes = 'settings.autoCleanMaxBytes';

/// 画质偏好枚举值（§5.4：'highest' | '720p'）
const String kQualityModeHighest = 'highest';
const String kQualityMode720p = '720p';

/// 手动代理缺省地址（sing-box 混合端口惯例；开关开启且地址为空时落此值，
/// 免去用户手填——用户反馈 2026-09-30）
const String kDefaultProxyAddress = '127.0.0.1:2080';

/// 设置快照（不可变）
class SettingsState {
  const SettingsState({
    required this.disclaimerVersion,
    required this.endpointConfigVersion,
    required this.concurrency,
    required this.qualityMode,
    required this.wifiOnly,
    required this.backupHistory,
    required this.proxyAddress,
    required this.proxyEnabled,
    required this.proxyAuto,
    required this.autoCleanDays,
    required this.autoCleanMaxBytes,
    this.disclaimerAcceptedAt,
  });

  final int disclaimerVersion;
  final int? disclaimerAcceptedAt;
  final int endpointConfigVersion;
  final int concurrency;
  final String qualityMode;
  final bool wifiOnly;

  /// 卸载重装后保留历史（自动备份到公共 Downloads，DESIGN §4.7）
  final bool backupHistory;

  /// 手动代理地址（"host:port"，如 127.0.0.1:2080；空 = 回落缺省
  /// [kDefaultProxyAddress]。移动网络无系统代理设置时的根本解法，
  /// DESIGN §6.9）
  final String proxyAddress;

  /// 手动代理总开关（用户反馈 2026-09-30）：关闭仅摘除注入（回落系统
  /// 代理/直连），地址保留——重开免重填。
  final bool proxyEnabled;

  /// 自动代理调节总开关（2026-10-07 增补，DESIGN §6.9）：方向 A（直连
  /// 失败→探测本地代理→自动启用）与方向 B（Wi-Fi 预检直连可用→自动
  /// 关闭）的仲裁键，默认开启。协调器见 core/proxy_auto.dart。
  final bool proxyAuto;

  /// 开关开启时的生效地址：空地址回落 [kDefaultProxyAddress]。
  String get effectiveProxyAddress =>
      proxyAddress.trim().isEmpty ? kDefaultProxyAddress : proxyAddress.trim();
  final int autoCleanDays;
  final int autoCleanMaxBytes;

  /// 已同意版本落后于当前条款版本 → 需要重新弹窗确认
  bool get needsDisclaimer => disclaimerVersion < kCurrentDisclaimerVersion;

  SettingsState copyWith({
    int? disclaimerVersion,
    int? disclaimerAcceptedAt,
    int? endpointConfigVersion,
    int? concurrency,
    String? qualityMode,
    bool? wifiOnly,
    bool? backupHistory,
    String? proxyAddress,
    bool? proxyEnabled,
    bool? proxyAuto,
    int? autoCleanDays,
    int? autoCleanMaxBytes,
  }) {
    return SettingsState(
      disclaimerVersion: disclaimerVersion ?? this.disclaimerVersion,
      disclaimerAcceptedAt: disclaimerAcceptedAt ?? this.disclaimerAcceptedAt,
      endpointConfigVersion: endpointConfigVersion ?? this.endpointConfigVersion,
      concurrency: concurrency ?? this.concurrency,
      qualityMode: qualityMode ?? this.qualityMode,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      backupHistory: backupHistory ?? this.backupHistory,
      proxyAddress: proxyAddress ?? this.proxyAddress,
      proxyEnabled: proxyEnabled ?? this.proxyEnabled,
      proxyAuto: proxyAuto ?? this.proxyAuto,
      autoCleanDays: autoCleanDays ?? this.autoCleanDays,
      autoCleanMaxBytes: autoCleanMaxBytes ?? this.autoCleanMaxBytes,
    );
  }
}

/// 缓存占用抽象：生产由持久层适配实现，测试注入假实现（离线）
abstract class CacheStore {
  Future<int> sizeBytes();

  /// 缓存统计（文件数 + 字节数），供清理确认弹窗列明实际影响。
  /// 默认实现回落 sizeBytes（文件数未知记 0）；生产侧覆写以给出精确计数。
  Future<({int fileCount, int totalBytes})> stats() async {
    return (fileCount: 0, totalBytes: await sizeBytes());
  }

  Future<void> clear();
}

/// 空实现：无持久层注入时报告 0（不崩、不触磁盘）
class EmptyCacheStore implements CacheStore {
  const EmptyCacheStore();

  @override
  Future<int> sizeBytes() async => 0;

  @override
  Future<({int fileCount, int totalBytes})> stats() async =>
      (fileCount: 0, totalBytes: 0);

  @override
  Future<void> clear() async {}
}

/// 缓存存储注入点（app.dart 用仓库实现 override）
final Provider<CacheStore> cacheStoreProvider = Provider<CacheStore>((_) => const EmptyCacheStore());

/// 设置控制器：AsyncNotifier，build 时从 shared_preferences 恢复。
class SettingsController extends AsyncNotifier<SettingsState> {
  /// 写操作串行门闩：setProxyEnabled/setProxyAddress 均跨 SharedPreferences
  /// 异步点，无锁并发会以陈旧快照互相覆盖（丢更新）。所有写路径经
  /// [_serialized] 排队，消除交错窗口（审查发现 #2，2026-09-30）。
  Future<void> _opGate = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final run = _opGate.then((_) => action());
    _opGate = run.then((_) {}, onError: (_) {});
    return run;
  }

  @override
  Future<SettingsState> build() async {
    final prefs = await SharedPreferences.getInstance();
    // 开关键首次读取（null）时的存量迁移：此前已保存非空地址的用户
    // 视为开启（升级不改变"地址已生效"的行为）；此前留空者保持关闭。
    // 迁移结果立即回写固化——否则"清空地址保存"落盘空串后，下次启动
    // getBool 仍 null 会按空串误判为关闭，代理静默摘除（审查发现 #1）。
    final savedAddress = prefs.getString(kPrefSettingsProxyAddress);
    final bool proxyEnabled;
    final enabledPref = prefs.getBool(kPrefSettingsProxyEnabled);
    if (enabledPref == null) {
      proxyEnabled = (savedAddress ?? '').isNotEmpty;
      await prefs.setBool(kPrefSettingsProxyEnabled, proxyEnabled);
    } else {
      proxyEnabled = enabledPref;
    }
    return SettingsState(
      disclaimerVersion: prefs.getInt(kPrefDisclaimerVersion) ?? 0,
      disclaimerAcceptedAt: prefs.getInt(kPrefDisclaimerAcceptedAt),
      endpointConfigVersion: prefs.getInt(kPrefEndpointConfigVersion) ?? 0,
      concurrency: prefs.getInt(kPrefSettingsConcurrency) ?? 2,
      qualityMode: prefs.getString(kPrefSettingsQualityMode) ?? kQualityModeHighest,
      wifiOnly: prefs.getBool(kPrefSettingsWifiOnly) ?? false,
      backupHistory: prefs.getBool(kPrefSettingsBackupHistory) ?? true,
      proxyAddress: savedAddress ?? kDefaultProxyAddress,
      proxyEnabled: proxyEnabled,
      // 全新独立开关无存量迁移歧义：读时默认即可，不写回（对齐 wifiOnly
      // 模式；proxyEnabled 当年写回是因其存量迁移有"空=跟随系统"旧语义
      // 需固化判定防翻转）
      proxyAuto: prefs.getBool(kPrefSettingsProxyAuto) ?? true,
      autoCleanDays: prefs.getInt(kPrefSettingsAutoCleanDays) ?? 3,
      autoCleanMaxBytes: prefs.getInt(kPrefSettingsAutoCleanMaxBytes) ?? 2 * 1024 * 1024 * 1024,
    );
  }

  SettingsState? get _current => state.value;

  /// 同意当前版本条款：写版本号 + 时间戳（§8.3）
  Future<void> acceptDisclaimer() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kPrefDisclaimerVersion, kCurrentDisclaimerVersion);
    await prefs.setInt(kPrefDisclaimerAcceptedAt, now);
    final cur = _current;
    if (cur != null) {
      state = AsyncData(cur.copyWith(
        disclaimerVersion: kCurrentDisclaimerVersion,
        disclaimerAcceptedAt: now,
      ));
    }
  }

  /// 重看条款后拒绝：把已同意版本回退为 0（下次启动重新闸门）
  Future<void> revokeDisclaimer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kPrefDisclaimerVersion, 0);
    await prefs.setInt(kPrefDisclaimerAcceptedAt, 0);
    final cur = _current;
    if (cur != null) {
      state = AsyncData(cur.copyWith(disclaimerVersion: 0, disclaimerAcceptedAt: 0));
    }
  }

  Future<void> setQualityMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefSettingsQualityMode, mode);
    final cur = _current;
    if (cur != null) state = AsyncData(cur.copyWith(qualityMode: mode));
  }

  Future<void> setConcurrency(int value) async {
    final clamped = value < 1 ? 1 : (value > 3 ? 3 : value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kPrefSettingsConcurrency, clamped);
    final cur = _current;
    if (cur != null) state = AsyncData(cur.copyWith(concurrency: clamped));
  }

  Future<void> setWifiOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrefSettingsWifiOnly, value);
    final cur = _current;
    if (cur != null) state = AsyncData(cur.copyWith(wifiOnly: value));
  }

  /// 卸载重装保留历史开关（§4.7）：关闭即停自动导出（已生成的备份文件保留）
  Future<void> setBackupHistory(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrefSettingsBackupHistory, value);
    final cur = _current;
    if (cur != null) state = AsyncData(cur.copyWith(backupHistory: value));
  }

  /// 设置手动代理地址（§6.9）：返回 false = 格式非法。校验与生效同源
  /// （core/app_http 的 parseProxyAddress），保存后按开关状态即时注入
  /// 运行时代理解析器（开关关闭时仅保存不生效），无需重启。
  Future<bool> setProxyAddress(String raw) =>
      _serialized(() async => _setProxyAddress(raw));

  Future<bool> _setProxyAddress(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isNotEmpty && parseProxyAddress(trimmed) == null) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefSettingsProxyAddress, trimmed);
    final cur = _current;
    if (cur != null) {
      final next = cur.copyWith(proxyAddress: trimmed);
      state = AsyncData(next);
      _applyProxy(next);
    } else {
      SystemProxy.setManualAddress(trimmed);
    }
    return true;
  }

  /// 手动代理总开关（用户反馈 2026-09-30）：关闭仅摘除注入（地址保留，
  /// 重开免重填）；开启时地址为空则落缺省 [kDefaultProxyAddress]。
  Future<void> setProxyEnabled(bool value) =>
      _serialized(() async => _setProxyEnabled(value));

  Future<void> _setProxyEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrefSettingsProxyEnabled, value);
    final cur = _current;
    if (cur == null) return;
    var next = cur.copyWith(proxyEnabled: value);
    if (value && cur.proxyAddress.trim().isEmpty) {
      await prefs.setString(kPrefSettingsProxyAddress, kDefaultProxyAddress);
      next = next.copyWith(proxyAddress: kDefaultProxyAddress);
    }
    state = AsyncData(next);
    _applyProxy(next);
  }

  /// 把设置快照注入运行时代理解析器：开关关闭 → null 摘除（回落系统
  /// 代理/直连）；开启 → 生效地址（空回落缺省）。
  void _applyProxy(SettingsState s) {
    SystemProxy.setManualAddress(
        s.proxyEnabled ? s.effectiveProxyAddress : null);
  }

  /// 自动代理调节总开关（§6.9 双向自动调节）：独立单键、不触碰代理
  /// 字段，无读改写交错面，不需 [_serialized]（对比：代理两键 setter
  /// 跨异步点必须串行）。关闭即冻结当前手动开关状态。
  Future<void> setProxyAuto(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrefSettingsProxyAuto, value);
    final cur = _current;
    if (cur != null) state = AsyncData(cur.copyWith(proxyAuto: value));
  }

  /// 缓存占用（字节）
  Future<int> cacheBytes() => ref.read(cacheStoreProvider).sizeBytes();

  /// 缓存统计（清理确认弹窗列明影响用）
  Future<({int fileCount, int totalBytes})> cacheStats() =>
      ref.read(cacheStoreProvider).stats();

  /// 一键清理缓存（P0 手动入口；P2 再挂自动策略）
  Future<void> clearCache() => ref.read(cacheStoreProvider).clear();
}

final AsyncNotifierProvider<SettingsController, SettingsState> settingsControllerProvider =
    AsyncNotifierProvider<SettingsController, SettingsState>(SettingsController.new);

/// 备份开关窄视图（main 装配监听用：仅备份开关变化时通知，不随整状态刷新）
final Provider<bool> backupHistoryFlagProvider = Provider<bool>((ref) {
  return ref.watch(settingsControllerProvider).value?.backupHistory ?? true;
});
