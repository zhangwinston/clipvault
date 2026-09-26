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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/data/tables.dart' as tbl;
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
            TaskTile(item: item, commands: commands),
        ]),
        _Section(title: AppStrings.dlSectionHistory, count: history.length, children: [
          for (final item in history)
            TaskTile(
              item: item,
              commands: commands,
              onOpenDetail: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HistoryScreen(item: item),
                ),
              ),
            ),
        ]),
      ],
    );
  }
}

/// 429 冷却横幅：秒级倒计时（截止时刻来自引擎通知流，此前被判空后丢弃）。
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              // 分区标题保持独立精确文案（§7.1-3 分区名），计数为辅助信息单独成 Text
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 6),
              Text(
                '($count)',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        ...children,
      ],
    );
  }
}
