/// 我的 Tab（DESIGN §4.6 / §7.1-4）：
/// IA 四分组（2026-10-04）——下载偏好 / 数据与存储 / 高级与网络 / 关于与合规，
/// 高频配置置顶、高技术属性的代理与网络排障沉底、合规与版本收口；
/// 免责声明重看（版本化）/ 权限说明 / 缓存占用与清理（行内化）
/// / 诊断信息（端点配置版本、App 版本）/ P2 偏好（默认画质、并发数、仅 Wi-Fi）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/backup/backup_service.dart' show activeBackupService;
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/core/net_diag.dart' show runNetworkDiagnostics;
import 'package:clipvault/settings/settings_controller.dart';
import 'package:clipvault/ui/common/disclaimer_dialog.dart';
import 'package:clipvault/ui/downloads/task_tile.dart' show formatBytes;
import 'package:clipvault/parse/parser_provider.dart'
    show endpointConfigRepositoryProvider;

/// App 版本（诊断展示用；包信息无依赖，随 pubspec 版本手动维护）
const String kAppVersion = '1.0.0';

/// 源码仓库地址（版本信息点击弹窗展示/复制）。
const String kRepoUrl = 'https://github.com/zhangwinston/clipvault';

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

  /// 网络诊断进行中（行内 spinner，UI 评审 R4）
  bool _diagRunning = false;

  /// 手动代理输入控制器（initState 由设置快照初始化）
  final TextEditingController _proxyCtrl = TextEditingController();

  /// 地址框焦点（didUpdateWidget 判断"用户是否正在编辑"用；
  /// hasFocus 在 FocusNode 上，TextEditingController 无此 getter）
  final FocusNode _proxyFocus = FocusNode();
  String? _proxyError;

  @override
  void initState() {
    super.initState();
    _proxyCtrl.text = widget.settings.proxyAddress;
    _refreshCache();
  }

  /// 开关开启且地址为空时控制器会落缺省地址（state 变化触发重建）——
  /// 同步进输入框：非编辑态全量同步；聚焦时仅当框为空才补缺省（否则
  /// 副标题"当前生效"与空框长期矛盾，审查发现 #3）。同步即清残留的
  /// 格式错误提示（审查发现 #4）。
  @override
  void didUpdateWidget(covariant _SettingsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.settings.proxyAddress != oldWidget.settings.proxyAddress &&
        (!_proxyFocus.hasFocus || _proxyCtrl.text.trim().isEmpty)) {
      _proxyCtrl.text = widget.settings.proxyAddress;
      if (_proxyError != null) setState(() => _proxyError = null);
    }
  }

  @override
  void dispose() {
    _proxyCtrl.dispose();
    _proxyFocus.dispose();
    super.dispose();
  }

  /// 失焦自动保存（UI 评审 R3：无保存按钮）：仅在有改动时触发，
  /// 避免每次点页面都写盘。
  void _maybeSaveProxy() {
    if (_proxyCtrl.text.trim() != widget.settings.proxyAddress) _saveProxy();
  }

  /// 保存手动代理（§6.9）：校验与生效同源（setProxyAddress 内部复用
  /// parseProxyAddress）。回车/失焦触发；开关关闭态保存以 toast 提示，
  /// 开启态由副标题"当前生效"即时反馈（UI 评审 R3 反馈瘦身）。
  Future<void> _saveProxy() async {
    final ok = await ref
        .read(settingsControllerProvider.notifier)
        .setProxyAddress(_proxyCtrl.text);
    if (!mounted) return;
    setState(() => _proxyError = ok ? null : AppStrings.toastProxyInvalid);
    if (ok && !widget.settings.proxyEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.toastProxySavedDisabled)),
      );
    }
  }

  /// 代理地址说明弹层（UI 评审 R2）：端口对照与开关语义长文迁入此处，
  /// 主界面常驻 helper 仅一行。
  Future<void> _showProxyHelp(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(AppStrings.settingsProxyHelpTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(AppStrings.settingsProxyPortsTable),
            const SizedBox(height: 12),
            const Text(AppStrings.settingsProxyKeepNote),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(AppStrings.settingsClose),
          ),
        ],
      ),
    );
  }

  /// 权限说明全文弹层（UI 评审 R1）：合规长文从常驻副标题迁为点开弹层，
  /// 与《使用协议》行同款交互；正文话术逐字保留（§8.2 只要求可达）。
  Future<void> _showPermissionDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(AppStrings.settingsPermissionTitle),
        content: const Text(AppStrings.settingsPermissionBody),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(AppStrings.settingsClose),
          ),
        ],
      ),
    );
  }

  /// 网络诊断（§6.9 配套）：分层定位代理/TUN 环境失败环节，
  /// 结果对话框给出每阶段耗时与结论数据。
  Future<void> _runNetDiag(BuildContext context) async {
    if (_diagRunning) return;
    setState(() => _diagRunning = true);
    // 行内 spinner 为主反馈；SnackBar 短文案兜底（无障碍/慢网提示）
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(AppStrings.diagRunning)),
    );
    final steps = await runNetworkDiagnostics();
    if (mounted) setState(() => _diagRunning = false);
    if (!context.mounted) return;
    final diagScheme = Theme.of(context).colorScheme;
    final stageNames = {
      'proxy': AppStrings.diagStageProxy,
      'dns': AppStrings.diagStageDns,
      'tcp': AppStrings.diagStageTcp,
      'https': AppStrings.diagStageHttps,
    };
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppStrings.diagTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 目标域名从标题挪入正文首行（UI 评审：域名不砸标题位）
              Text(AppStrings.diagTargetHost,
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 4),
              for (final s in steps)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        // 主题语义色替代硬编码纯色（暗色对比/语义兜底）
                        Icon(
                          s.ok ? Icons.check_circle : Icons.cancel,
                          size: 18,
                          color: s.ok ? diagScheme.primary : diagScheme.error,
                        ),
                        const SizedBox(width: 6),
                        // 阶段行与 bodySmall 正文同框不跨两级（字号统一评审）
                        Text(
                          '${stageNames[s.stage] ?? s.stage} '
                          '(${s.elapsed.inMilliseconds}ms)',
                          style: Theme.of(ctx).textTheme.bodyMedium,
                        ),
                      ]),
                      Text(s.detail,
                          style: Theme.of(ctx).textTheme.bodySmall),
                    ],
                  ),
                ),
              const Divider(),
              Text(AppStrings.diagHint,
                  style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ),
        ),
        actions: [
          // 只读结果弹窗无「取消」语义（UI 评审 quickWin）
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(AppStrings.settingsClose),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshCache() async {
    final bytes = await ref.read(settingsControllerProvider.notifier).cacheBytes();
    if (mounted) setState(() => _cacheBytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final scheme = Theme.of(context).colorScheme;
    // IA 四分组（2026-10-04）：高频偏好置顶；备份与缓存合并为「数据与存储」；
    // 代理/诊断/解析服务收口「高级与网络」；版本/权限/协议收口「关于与合规」。
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // ---- ① 下载偏好 ----
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
                // 值由 SegmentedButton 选中段自表达，标题不再拼接冗余数字；
                // 标题字号回落默认 bodyLarge——此前显式 bodyMedium 与同卡
                // 兄弟行（ListTile/SwitchListTile 标题）不同级（UI 评审 2026-09-30）
                Text(
                  AppStrings.settingsConcurrency,
                  style: Theme.of(context).textTheme.bodyLarge,
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
                    // 紧凑密度（2026-10-04）：三段选择器不再占满整行高，
                    // 行高收窄与兄弟 ListTile 视觉齐平
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 13),
                    ),
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
        // ---- ② 数据与存储 ----
        _header(context, AppStrings.settingsSectionStorage),
        _group([
          SwitchListTile(
            secondary: const Icon(Icons.backup_outlined),
            title: Text(AppStrings.settingsBackupKeep),
            subtitle: Text(AppStrings.settingsBackupKeepHint),
            value: settings.backupHistory,
            onChanged: (value) => ref
                .read(settingsControllerProvider.notifier)
                .setBackupHistory(value),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                // 纯文本按钮（去图标）：≤320dp 窄屏下图标+全角标签超半宽
                // 致换行、两键不齐；标签自释义无歧义（UI 评审 2026-09-30）
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _backupNow(context),
                    child: Text(AppStrings.actionBackupNow),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _restoreBackup(context),
                    child: Text(AppStrings.actionRestoreBackup),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 缓存清理行内化（2026-10-04）：占用值 + 操作收进单个标准
          // ListTile，替代「占用行 + 通栏大按钮」两行排版
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: Text(AppStrings.settingsCacheUsage),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _cacheBytes == null ? '--' : formatBytes(_cacheBytes!),
                  style: _metaValue(context),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _confirmCleanCache(context),
                  child: const Text(AppStrings.settingsCacheClean),
                ),
              ],
            ),
          ),
        ]),
        // ---- ③ 高级与网络 ----
        _header(context, AppStrings.settingsSectionAdvanced),
        _group([
          // 总开关（用户反馈 2026-09-30）：一键启停，地址常驻免重填；
          // 副标题仅在开启态呈现生效地址（空地址回落缺省 127.0.0.1:2080），
          // 关闭态不渲染（UI 评审：开关态由 Switch 自表达）
          SwitchListTile(
            secondary: const Icon(Icons.vpn_key_outlined),
            title: Text(AppStrings.settingsProxyToggle),
            subtitle: settings.proxyEnabled
                ? Text(
                    // 长地址（自建网关/IPv6）超副标题宽不换行，尾部截断保单行
                    AppStrings.settingsProxyActiveNow +
                        settings.effectiveProxyAddress,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : null,
            value: settings.proxyEnabled,
            onChanged: (value) => ref
                .read(settingsControllerProvider.notifier)
                .setProxyEnabled(value),
          ),
          // 地址框仅开启态展开（2026-10-04）：代理是高技术属性配置，
          // 关闭态收起输入框/TUN 提示/ⓘ 的整行横排臃肿区，开关即全部界面；
          // 地址仍持久保留（settings 层语义），重开免重填。
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 250),
            crossFadeState: settings.proxyEnabled
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _proxyCtrl,
                focusNode: _proxyFocus,
                decoration: InputDecoration(
                  labelText: AppStrings.settingsProxyManualLabel,
                  hintText: AppStrings.settingsProxyManualHint,
                  helperText: AppStrings.settingsProxyManualHelper,
                  errorText: _proxyError,
                  suffixIcon: IconButton(
                    tooltip: AppStrings.settingsProxyHelpTitle,
                    icon: const Icon(Icons.help_outline),
                    onPressed: () => _showProxyHelp(context),
                  ),
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (_) => _saveProxy(),
                onTapOutside: (_) => _maybeSaveProxy(),
              ),
            ),
            secondChild: const SizedBox(width: double.infinity),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 副标题修正：此前错用代理输入框 hint（文案错配，UI 评审 quickWin）；
          // 运行期行内 spinner 替代纯文字反馈（R4），完成即弹结果框
          ListTile(
            leading: const Icon(Icons.network_check),
            title: Text(AppStrings.actionNetDiag),
            // 提示语挪至行尾 meta 徽标（2026-09-30：副标题不挂长文案，
            // 与版本/端点行行尾弱化样式同体系）；运行期 spinner 顶替提示位
            trailing: _diagRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          AppStrings.settingsNetDiagHint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _metaValue(context),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
            onTap: _diagRunning ? null : () => _runNetDiag(context),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(AppStrings.settingsEndpointVersion),
            // 只读声明落在它解释的行上（UI 评审 quickWin，替代原页脚）
            subtitle: Text(AppStrings.settingsEndpointHint),
            // 优先读端点配置仓库当前生效版本（接线后随 assets 加载/远端热更
            // 刷新；仓库未就绪时回落 prefs 快照值）
            trailing: Text(
              'v${ref.watch(endpointConfigRepositoryProvider).value?.current.version ?? settings.endpointConfigVersion}',
              style: _metaValue(context),
            ),
          ),
        ]),
        // ---- ④ 关于与合规 ----
        _header(context, AppStrings.settingsSectionAbout),
        _group([
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(AppStrings.settingsVersion),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // v 前缀与端点版本行统一版本体系观感（UI 评审 quickWin）
                Text('v$kAppVersion', style: _metaValue(context)),
                Icon(Icons.chevron_right,
                    size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
            // 点击展示仓库链接（用户反馈需求）
            onTap: () => _showRepoDialog(context),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 权限合规长文从常驻副标题迁入点开弹层（UI 评审 R1），
          // 与《使用协议》行同款交互
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(AppStrings.settingsPermissionTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showPermissionDialog(context),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
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
      ],
    );
  }

  /// 行尾数值统一弱化样式（版本号/缓存占用/端点版本）：13px w500 灰、
  /// 表格数字对齐——行尾 meta 不与行标题争夺视觉权重（UI 评审 2026-09-30）
  TextStyle _metaValue(BuildContext context) => TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// 版本信息点击弹窗：展示 GitHub 仓库链接（可选中复制）+ 一键复制。
  Future<void> _showRepoDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(AppStrings.settingsVersion),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${AppStrings.appName} v$kAppVersion'),
            const SizedBox(height: 12),
            Text(AppStrings.settingsRepoLink),
            const SizedBox(height: 4),
            SelectableText(
              kRepoUrl,
              style: Theme.of(dialogContext)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Theme.of(dialogContext).colorScheme.primary),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: kRepoUrl));
              Navigator.of(dialogContext).pop();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text(AppStrings.settingsLinkCopied)),
                );
              }
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text(AppStrings.settingsCopyLink),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(AppStrings.settingsClose),
          ),
        ],
      ),
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
  /// 底与 12px 圆角）。水平 16 与组标题/AppBar 标题同线（UI 评审对齐统一）。
  Widget _group(List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Card(child: Column(children: children)),
    );
  }

  /// 清理缓存前置确认（P0：此操作实际删除视频本地副本，必须列明影响）。
  /// 立即全量备份（§4.7 手动入口；自动导出之外的保险动作）
  Future<void> _backupNow(BuildContext context) async {
    final svc = activeBackupService;
    if (svc == null) return;
    final ok = await svc.exportNow();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? AppStrings.toastBackupDone : AppStrings.toastBackupFailed),
    ));
  }

  /// 从备份恢复（§4.7 手动入口；按 (tweetId, bitrate) 去重合并）
  Future<void> _restoreBackup(BuildContext context) async {
    final svc = activeBackupService;
    if (svc == null) return;
    final n = await svc.restoreManual();
    if (!context.mounted) return;
    final String msg;
    if (n < 0) {
      msg = AppStrings.toastRestoreEmpty;
    } else if (n == 0) {
      msg = AppStrings.toastRestoreUptodate;
    } else {
      msg = AppStrings.toastRestoreDone.replaceFirst('{n}', '$n');
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

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
