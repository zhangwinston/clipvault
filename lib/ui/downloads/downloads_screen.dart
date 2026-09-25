/// 下载 Tab（DESIGN §7.1-3）：进行中 / 等待队列 / 失败 / 历史 四分区。
///
/// - 数据来自 downloadsWatchProvider（StreamProvider，§9-1 双流合并）；
/// - 进行中区：进度/速率/ETA + 暂停/继续/取消；
/// - 失败区：错误话术 + 一键重试；
/// - 429 冷却提示横幅（引擎 notices 的 rateLimitCooldownStarted/Ended 驱动，§4.3）；
/// - 历史区：缩略图/标题/下载时间/清晰度/大小，点击进 HistoryScreen。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';
import 'package:clipvault/ui/history/history_screen.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(downloadsWatchProvider);
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.tabDownloads)),
      body: asyncItems.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        // 固定文案收口（§9-12）：不向用户渲染原始异常串
        error: (e, _) =>
            const Center(child: Text(AppStrings.errDownloadFailed)),
        data: (items) => _DownloadList(items: items),
      ),
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
    final failed = items.where((t) => t.isFailed).toList(growable: false);
    final history =
        items.where((t) => t.isHistory).toList(growable: false);
    // 429 冷却观察口（引擎 notices：rateLimitCooldownStarted 携带截止时刻）
    final cooling = ref.watch(coolingProvider).value != null;

    if (items.isEmpty) {
      return Center(child: Text(AppStrings.dlEmpty));
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        if (cooling)
          // 429 全队列 30s 冷却提示（§4.3；引擎侧暂停，UI 提示自动继续）
          Material(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.hourglass_top),
                  const SizedBox(width: 8),
                  Expanded(child: Text(AppStrings.cooldownNotice)),
                ],
              ),
            ),
          ),
        _Section(title: AppStrings.dlSectionActive, count: active.length, children: [
          for (final item in active)
            TaskTile(item: item, commands: commands),
        ]),
        _Section(title: AppStrings.dlSectionQueued, count: queued.length, children: [
          for (final item in queued)
            TaskTile(item: item, commands: commands),
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
