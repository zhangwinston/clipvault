/// 设置控制器：免责声明版本化（§8.3）+ P0/P2 偏好 + 缓存清理策略（§4.6）。
///
/// - 偏好落 shared_preferences，键名严格按 DESIGN §5.4；
/// - [SharedPreferences] 在测试中经 `SharedPreferences.setMockInitialValues` 离线注入；
/// - 缓存统计/清理经 [CacheStore] 抽象注入（生产由 app.dart 绑定仓库实现）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
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
const String kPrefSettingsAutoCleanDays = 'settings.autoCleanDays';
const String kPrefSettingsAutoCleanMaxBytes = 'settings.autoCleanMaxBytes';

/// 画质偏好枚举值（§5.4：'highest' | '720p'）
const String kQualityModeHighest = 'highest';
const String kQualityMode720p = '720p';

/// 设置快照（不可变）
class SettingsState {
  const SettingsState({
    required this.disclaimerVersion,
    required this.endpointConfigVersion,
    required this.concurrency,
    required this.qualityMode,
    required this.wifiOnly,
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
  @override
  Future<SettingsState> build() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsState(
      disclaimerVersion: prefs.getInt(kPrefDisclaimerVersion) ?? 0,
      disclaimerAcceptedAt: prefs.getInt(kPrefDisclaimerAcceptedAt),
      endpointConfigVersion: prefs.getInt(kPrefEndpointConfigVersion) ?? 0,
      concurrency: prefs.getInt(kPrefSettingsConcurrency) ?? 2,
      qualityMode: prefs.getString(kPrefSettingsQualityMode) ?? kQualityModeHighest,
      wifiOnly: prefs.getBool(kPrefSettingsWifiOnly) ?? false,
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
