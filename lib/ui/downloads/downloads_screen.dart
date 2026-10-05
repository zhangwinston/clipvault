/// 下载 Tab（DESIGN §7.1-3）：进行中 / 等待队列 / 失败 / 历史 四分区。
///
/// - 数据来自 downloadsWatchProvider（StreamProvider，§9-1 双流合并）；
/// - 进行中区：进度/速率/ETA + 暂停/继续/取消；
/// - 失败区：错误话术 + 一键重试（用户主动取消的任务归入历史区，不计失败）；
/// - 429 冷却横幅带秒级倒计时（coolingProvider 携带的截止时刻此前被丢弃）；
/// - 仅 Wi-Fi 挂起 / 冷却暂停均有专属状态标签（不再与普通排队/暂停混淆）；
/// - 横幅 liveRegion + 冷却开始主动朗读（读屏可达性）；
/// - 空态带「去解析第一个视频」行动按钮；错误态带重试。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/backup/backup_service.dart' show activeBackupService;
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/data/tables.dart' as tbl;
import 'package:clipvault/player/player_screen.dart';
import 'package:clipvault/settings/settings_controller.dart';
import 'package:clipvault/ui/common/info_banner.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';
import 'package:clipvault/ui/history/history_screen.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(downloadsWatchProvider);
    // 冷却开始/结束的读屏主动通告（P1-12）
    ref.listen<AsyncValue<DateTime?>>(coolingProvider, (previous, next) {
      final until = next.value;
      final was = previous?.value;
      if (until != null && was == null) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          AppStrings.cooldownNotice,
          TextDirection.ltr,
        );
      }
    });
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.tabDownloads)),
      body: asyncItems.when(
        loading: () => const _DownloadsSkeleton(),
        // 固定文案收口（§9-12）：不向用户渲染原始异常串；
        // 此场景是本地列表加载失败（用户并未发起下载），用通用兜底 +
        // 重试按钮，不再误用「下载失败」。
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 40),
              const SizedBox(height: 8),
              const Text(AppStrings.errGeneric),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => ref.invalidate(downloadsWatchProvider),
                icon: const Icon(Icons.refresh),
                label: const Text(AppStrings.actionRetry),
              ),
            ],
          ),
        ),
        data: (items) => _DownloadList(items: items),
      ),
    );
  }
}

/// 下载 Tab 空态/加载骨架的占位行。
class _DownloadsSkeleton extends StatelessWidget {
  const _DownloadsSkeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget bone(double w, double h, {bool circular = false}) => Container(
          width: w,
          height: h,
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: color,
            borderRadius: circular ? null : BorderRadius.circular(6),
            shape: circular ? BoxShape.circle : BoxShape.rectangle,
          ),
        );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                bone(72, 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      bone(double.infinity, 14),
                      bone(180, 10),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DownloadList extends ConsumerWidget {
  const _DownloadList({required this.items});

  final List<TaskItem> items;

  /// 空态一键恢复（§4.7）：直读失败自动回落 SAF 选择器（预定位
  /// Download/ClipVault）；恢复后按需申请相册读权限复活视频路径
  ///（孤儿视频无权限不可见，见 BackupService._reviveVideoPaths）。
  Future<void> _restoreFromBackup(BuildContext context) async {
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final commands = ref.watch(downloadCommandsProvider);
    final active = items.where((t) => t.isActive).toList(growable: false);
    final queued = items.where((t) => t.isQueued).toList(growable: false);
    // 用户主动取消不是失败：canceled 归入历史区（行内已有「已取消」标签），
    // 失败分区与计数只含真正的 failed。
    final failed = items
        .where((t) => t.status == tbl.DownloadStatus.failed)
        .toList(growable: false);
    final history = items
        .where((t) => t.isHistory || t.status == tbl.DownloadStatus.canceled)
        .toList(growable: false);
    // 429 冷却观察口（引擎 notices：rateLimitCooldownStarted 携带截止时刻）
    final coolingUntil = ref.watch(coolingProvider).value;
    // 仅 Wi-Fi 挂起判定（偏好开启且当前非 Wi-Fi → queued 行显示专属标签）
    final wifiOnly =
        ref.watch(settingsControllerProvider).value?.wifiOnly ?? false;
    final onWifi = ref.watch(onWifiProvider).value ?? true;
    final waitingWifi = wifiOnly && !onWifi;

    if (items.isEmpty) {
      // 空态视觉锚点（主题 F：此前 48px 裸图标+一行字单薄）——
      // 72px 图标置于 120px primaryContainer 圆底 + CTA 宽度收敛。
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.movie_outlined,
                size: 72,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            const Text(AppStrings.dlEmpty,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  // 空态行动入口：切回首页开始第一次解析（P1-3）
                  onPressed: () => ref.read(homeTabProvider.notifier).select(0),
                  icon: const Icon(Icons.link),
                  label: const Text(AppStrings.dlEmptyAction),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // 重装恢复入口（2026-10-05）：备份文件在公共 Downloads 跨卸载
            // 保留，但 Android 11+ 孤儿行对重装 App 不可见，静默读不可行
            // ——一键触发 SAF 选择（预定位 Download/ClipVault，两步点完）
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _restoreFromBackup(context),
                  icon: const Icon(Icons.settings_backup_restore),
                  label: const Text(AppStrings.dlRestoreFromBackup),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        if (coolingUntil != null)
          // 429 全队列冷却提示（§4.3；带倒计时，读屏 liveRegion）
          _CooldownBanner(until: coolingUntil),
        _Section(title: AppStrings.dlSectionActive, count: active.length, children: [
          for (final item in active)
            TaskTile(
              item: item,
              commands: commands,
              cooldownActive: coolingUntil != null,
            ),
        ]),
        _Section(title: AppStrings.dlSectionQueued, count: queued.length, children: [
          for (final item in queued)
            TaskTile(
              item: item,
              commands: commands,
              waitingWifi: waitingWifi,
              cooldownActive: coolingUntil != null,
            ),
        ]),
        _Section(title: AppStrings.dlSectionFailed, count: failed.length, children: [
          for (final item in failed)
            TaskTile(
              item: item,
              commands: commands,
              onDeleteRecord: () =>
                  _confirmDeleteRecord(context, commands, item),
            ),
        ]),
        // 历史区默认折叠（视觉评审主题 H：已完成只增不减，平铺导致页面
        // 无限增长；折叠后活跃区始终在首屏）
        _HistorySection(count: history.length, children: [
          for (final item in history)
            TaskTile(
              item: item,
              commands: commands,
              onOpenDetail: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HistoryScreen(item: item),
                ),
              ),
              onDeleteRecord: () =>
                  _confirmDeleteRecord(context, commands, item),
              // ⋮ 菜单动作（2026-10-04）：文件缺失时播放/分享置灰
              onPlay: item.filePath == null
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              PlayerScreen(filePath: item.filePath!),
                        ),
                      ),
              onShare: item.filePath == null
                  ? null
                  : () async {
                      final ok = await ref
                          .read(historyCommandsProvider)
                          .shareFile(item.filePath!);
                      // 按钮存在就必须有可感知的响应（分享面板拉起失败反馈）
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text(AppStrings.shareUnavailable)),
                        );
                      }
                    },
              onCopyLink: () {
                Clipboard.setData(
                  ClipboardData(
                    text: 'https://x.com/i/status/${item.tweetId}',
                  ),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text(AppStrings.toastLinkCopied)),
                );
              },
            ),
        ]),
      ],
    );
  }

  /// 删除记录确认（用户反馈 2026-09-30）：缺省仅删记录行、视频文件保留
  /// ——与历史详情页的「记录+文件」彻底删除互补；已取消/失败/已完成行均可删。
  /// 取消占视觉最强位、删除用 error 前景色（破坏性操作确认惯例同 §4.5）。
  Future<void> _confirmDeleteRecord(
    BuildContext context,
    DownloadCommands commands,
    TaskItem item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(AppStrings.dlDeleteRecordTitle),
        content: const Text(AppStrings.dlDeleteRecordBody),
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
            child: const Text(AppStrings.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await commands.deleteRecord(item.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.toastRecordDeleted)),
        );
      }
    }
  }
}
/// 视觉语言统一为 InfoBanner（secondaryContainer + 圆角 + accent 竖条，
/// 此前为 tertiaryContainer 蓝紫通栏，脱离品牌色系）。
class _CooldownBanner extends StatefulWidget {
  const _CooldownBanner({required this.until});

  final DateTime until;

  @override
  State<_CooldownBanner> createState() => _CooldownBannerState();
}

class _CooldownBannerState extends State<_CooldownBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining =
        widget.until.difference(DateTime.now()).inSeconds.clamp(0, 999);
    return Semantics(
      // 状态重大变化对读屏用户可达（P1-12）
      liveRegion: true,
      child: InfoBanner(
        icon: Icons.hourglass_top,
        // 琥珀警示图标（勿用 tertiary 蓝紫——fromSeed 的 tertiary 脱离品牌色系）
        iconColor: cooldownAmber(Theme.of(context).brightness),
        message: '${AppStrings.cooldownNoticePrefix}'
            '$remaining'
            '${AppStrings.cooldownNoticeSuffix}',
        emphasizeNumbers: true,
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.count, required this.children});

  final String title;
  final int count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // 分区呼吸间隔（视觉评审 layout-2：此前区间 0 间距）
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                // 分区标题（§7.1-3 分区名保持独立精确文案）
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(width: 8),
                // 计数胶囊徽章（视觉评审主题 H：此前「(N)」灰字）
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // 标题下分割线的行内延伸（分组边界信号）
                const Expanded(
                  child: Divider(height: 1),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

/// 历史分区：ExpansionTile 默认收起（活跃区始终在首屏）。
class _HistorySection extends StatelessWidget {
  const _HistorySection({required this.count, required this.children});

  final int count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return ExpansionTile(
      initiallyExpanded: false,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Row(
        children: [
          Text(AppStrings.dlSectionHistory,
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ),
        ],
      ),
      children: [
        ...children,
        const SizedBox(height: 8),
      ],
    );
  }
}
