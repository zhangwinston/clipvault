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
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _header(context, AppStrings.settingsSectionLegal),
        ListTile(
          leading: const Icon(Icons.gavel_outlined),
          title: Text(AppStrings.settingsDisclaimerRevisit),
          subtitle: Text('${AppStrings.settingsDisclaimerVersionPrefix}'
              '${settings.disclaimerVersion} → v$kCurrentDisclaimerVersion'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showDisclaimerDialog(
            context,
            // 重看场景：同意则刷新版本记录；拒绝保持原状（首次启动路径才强制退出）
            onDecline: () {},
          ).then((accepted) {
            if (accepted) ref.read(settingsControllerProvider.notifier).acceptDisclaimer();
          }),
        ),
        _header(context, AppStrings.settingsSectionPermission),
        ListTile(
          leading: const Icon(Icons.privacy_tip_outlined),
          title: Text(AppStrings.settingsPermissionTitle),
          subtitle: Text(AppStrings.settingsPermissionBody),
        ),
        _header(context, AppStrings.settingsSectionCache),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(AppStrings.settingsCacheUsage),
          trailing: Text(_cacheBytes == null ? '--' : formatBytes(_cacheBytes!)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: () async {
              await ref.read(settingsControllerProvider.notifier).clearCache();
              await _refreshCache();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text(AppStrings.settingsCacheCleaned)),
                );
              }
            },
            icon: const Icon(Icons.cleaning_services_outlined),
            label: const Text(AppStrings.settingsCacheClean),
          ),
        ),
        _header(context, AppStrings.settingsSectionPrefs),
        ListTile(
          leading: const Icon(Icons.high_quality_outlined),
          title: Text(AppStrings.settingsQualityMode),
          trailing: DropdownButton<String>(
            value: settings.qualityMode == kQualityMode720p
                ? kQualityMode720p
                : kQualityModeHighest,
            onChanged: (value) {
              if (value != null) {
                ref.read(settingsControllerProvider.notifier).setQualityMode(value);
              }
            },
            items: const [
              DropdownMenuItem(value: kQualityModeHighest, child: Text(AppStrings.settingsQualityHighest)),
              DropdownMenuItem(value: kQualityMode720p, child: Text(AppStrings.settingsQuality720p)),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.format_list_numbered),
          title: Text('${AppStrings.settingsConcurrency}：${settings.concurrency}'),
          subtitle: Slider(
            value: settings.concurrency.toDouble(),
            min: 1,
            max: 3,
            divisions: 2,
            label: '${settings.concurrency}',
            onChanged: (value) =>
                ref.read(settingsControllerProvider.notifier).setConcurrency(value.toInt()),
          ),
        ),
          SwitchListTile(
            secondary: const Icon(Icons.wifi),
            title: Text(AppStrings.settingsWifiOnly),
            value: settings.wifiOnly,
            onChanged: (value) =>
                ref.read(settingsControllerProvider.notifier).setWifiOnly(value),
          ),
        _header(context, AppStrings.settingsSectionDiag),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(AppStrings.settingsVersion),
          trailing: const Text(kAppVersion),
        ),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: Text(AppStrings.settingsEndpointVersion),
          // 优先读端点配置仓库当前生效版本（接线后随 assets 加载/远端热更
          // 刷新；仓库未就绪时回落 prefs 快照值）
          trailing: Text(
            'v${ref.watch(endpointConfigRepositoryProvider).value?.current.version ?? settings.endpointConfigVersion}',
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            AppStrings.settingsDiagHint,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}
