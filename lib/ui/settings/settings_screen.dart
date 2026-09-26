/// 我的 Tab（DESIGN §4.6 / §7.1-4）：
/// 免责声明重看（版本化）/ 权限说明 / 缓存占用与清理 / 诊断信息（端点配置版本、App 版本）
/// / P2 偏好区（默认画质、并发数、仅 Wi-Fi）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/settings/settings_controller.dart';
import 'package:clipvault/ui/common/disclaimer_dialog.dart';
import 'package:clipvault/ui/downloads/task_tile.dart' show formatBytes;
import 'package:clipvault/ui/home/home_screen.dart' show endpointConfigRepositoryProvider;

/// App 版本（诊断展示用；包信息无依赖，随 pubspec 版本手动维护）
const String kAppVersion = '1.0.0';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSettings = ref.watch(settingsControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.tabSettings)),
      body: asyncSettings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        // 固定文案收口（§9-12）：不向用户渲染原始异常串
        error: (e, _) =>
            const Center(child: Text(AppStrings.errGeneric)),
        data: (settings) => _SettingsBody(settings: settings),
      ),
    );
  }
}

class _SettingsBody extends ConsumerStatefulWidget {
  const _SettingsBody({required this.settings});

  final SettingsState settings;

  @override
  ConsumerState<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends ConsumerState<_SettingsBody> {
  int? _cacheBytes;

  @override
  void initState() {
    super.initState();
    _refreshCache();
  }

  Future<void> _refreshCache() async {
    final bytes = await ref.read(settingsControllerProvider.notifier).cacheBytes();
    if (mounted) setState(() => _cacheBytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final scheme = Theme.of(context).colorScheme;
    // 视觉评审主题 H：分组卡片化（此前裸 ListView 平铺无容器层级）+
    // 免责副标题版本语义修正 + 并发数滑条改 SegmentedButton。
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _header(context, AppStrings.settingsSectionLegal),
        _group([
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: Text(AppStrings.settingsDisclaimerRevisit),
            subtitle: Text(_disclaimerSubtitle(settings.disclaimerVersion)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showDisclaimerDialog(
              context,
              // 重看场景：同意则刷新版本记录；拒绝保持原状（首次启动路径才强制退出）
              onDecline: () {},
              scenario: DisclaimerScenario.review,
            ).then((accepted) {
              if (accepted) {
                ref.read(settingsControllerProvider.notifier).acceptDisclaimer();
              }
            }),
          ),
        ]),
        _header(context, AppStrings.settingsSectionPermission),
        _group([
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(AppStrings.settingsPermissionTitle),
            subtitle: Text(AppStrings.settingsPermissionBody),
          ),
        ]),
        _header(context, AppStrings.settingsSectionCache),
        _group([
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(AppStrings.settingsCacheUsage),
            trailing:
                Text(_cacheBytes == null ? '--' : formatBytes(_cacheBytes!)),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _confirmCleanCache(context),
                icon: const Icon(Icons.cleaning_services_outlined),
                label: const Text(AppStrings.settingsCacheClean),
              ),
            ),
          ),
        ]),
        _header(context, AppStrings.settingsSectionPrefs),
        _group([
          ListTile(
            leading: const Icon(Icons.high_quality_outlined),
            title: Text(AppStrings.settingsQualityMode),
            trailing: DropdownButton<String>(
              value: settings.qualityMode == kQualityMode720p
                  ? kQualityMode720p
                  : kQualityModeHighest,
              onChanged: (value) {
                if (value != null) {
                  ref
                      .read(settingsControllerProvider.notifier)
                      .setQualityMode(value);
                }
              },
              items: const [
                DropdownMenuItem(
                    value: kQualityModeHighest,
                    child: Text(AppStrings.settingsQualityHighest)),
                DropdownMenuItem(
                    value: kQualityMode720p,
                    child: Text(AppStrings.settingsQuality720p)),
              ],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${AppStrings.settingsConcurrency}：${settings.concurrency}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 1, label: Text('1')),
                      ButtonSegment(value: 2, label: Text('2')),
                      ButtonSegment(value: 3, label: Text('3')),
                    ],
                    selected: {settings.concurrency},
                    onSelectionChanged: (selection) => ref
                        .read(settingsControllerProvider.notifier)
                        .setConcurrency(selection.first),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            secondary: const Icon(Icons.wifi),
            title: Text(AppStrings.settingsWifiOnly),
            value: settings.wifiOnly,
            onChanged: (value) => ref
                .read(settingsControllerProvider.notifier)
                .setWifiOnly(value),
          ),
        ]),
        _header(context, AppStrings.settingsSectionDiag),
        _group([
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(AppStrings.settingsVersion),
            trailing: const Text(kAppVersion),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(AppStrings.settingsEndpointVersion),
            // 优先读端点配置仓库当前生效版本（接线后随 assets 加载/远端热更
            // 刷新；仓库未就绪时回落 prefs 快照值）
            trailing: Text(
              'v${ref.watch(endpointConfigRepositoryProvider).value?.current.version ?? settings.endpointConfigVersion}',
            ),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Text(
            AppStrings.settingsDiagHint,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// 免责副标题：未同意/已同意当前版/曾同意旧版三种语义
  ///（此前恒显「1 → v1」，版本相等时文案无意义）。
  String _disclaimerSubtitle(int version) {
    if (version <= 0) return AppStrings.settingsDisclaimerNone;
    if (version == kCurrentDisclaimerVersion) {
      return '${AppStrings.settingsDisclaimerVersionPrefix}v$version';
    }
    return '${AppStrings.settingsDisclaimerVersionPrefix}'
        'v$version → v$kCurrentDisclaimerVersion';
  }

  Widget _header(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }

  /// 分组容器（主题 H：卡片化分组；Card 全局主题已带 surfaceContainerLow
  /// 底与 12px 圆角）。
  Widget _group(List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Card(child: Column(children: children)),
    );
  }

  /// 清理缓存前置确认（P0：此操作实际删除视频本地副本，必须列明影响）。
  Future<void> _confirmCleanCache(BuildContext context) async {
    final notifier = ref.read(settingsControllerProvider.notifier);
    final stats = await notifier.cacheStats();
    if (!context.mounted) return;
    if (stats.totalBytes <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.settingsCacheEmpty)),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(AppStrings.settingsCacheCleanConfirmTitle),
        content: Text(
          '${AppStrings.settingsCacheCleanConfirmPrefix}'
          '${stats.fileCount}'
          '${AppStrings.settingsCacheCleanConfirmMiddle}'
          '${formatBytes(stats.totalBytes)}'
          '${AppStrings.settingsCacheCleanConfirmSuffix}',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(AppStrings.actionCancel),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(AppStrings.settingsCacheClean),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await notifier.clearCache();
      await _refreshCache();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.settingsCacheCleaned)),
        );
      }
    }
  }
}
