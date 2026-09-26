/// 历史详情页（P1 操作集，DESIGN §4.5 / §7.1-3）：
/// 播放（PlayerScreen）/ 系统分享 / 保存至相册（常驻入口，文案随入册状态）/ 删除。
///
/// [HistoryCommands] 为 UI 命令抽象（测试注入假实现）；
/// 生产适配 [RepoHistoryCommands]（对 S4 仓库与 S5 相册保存器的签名假设集中于此）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/data/database.dart' show DownloadRecord;
import 'package:clipvault/player/player_screen.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';

/// 历史条目命令抽象
abstract class HistoryCommands {
  Future<void> delete(int id);

  /// 重新保存至相册：返回是否成功（失败回落沙盒说明，§4.4）
  Future<bool> resaveToGallery(int id, String filePath);

  /// 系统分享（share_plus）：返回是否成功（失败由调用方给出可感知反馈，
  /// 不允许按钮按下毫无反应的静默失效）。
  Future<bool> shareFile(String filePath);
}

/// 生产实现：仓库 + 相册保存器 + 分享通道适配（签名假设集中于此）
class RepoHistoryCommands implements HistoryCommands {
  RepoHistoryCommands(this._ref);

  final Ref _ref;

  /// 相册名（DESIGN §8.4：ClipVault）
  static const String albumName = 'ClipVault';

  @override
  Future<void> delete(int id) async {
    // 级联：引擎中仍有该任务则先取消（行删除后引擎回写落空即可）
    final engine = _ref.read(downloadEngineProvider);
    if (engine.task(EngineDownloadCommands.engineIdOf(id)) != null) {
      engine.cancel(EngineDownloadCommands.engineIdOf(id));
    }
    // 接收被删行：物理文件 best-effort 清理（仓库契约「删除仅删记录行，
    // 文件由调用方依据返回行执行」；不清即成缓存统计/清理均不可见的孤儿）
    final row = await _ref.read(historyRepositoryProvider).deleteById(id);
    if (row == null) return;
    for (final path in [row.filePath, row.partPath]) {
      if (path == null || path.isEmpty) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 单文件删除失败（占用/权限）忽略，不阻断记录删除
      }
    }
  }

  @override
  Future<bool> resaveToGallery(int id, String filePath) async {
    // GallerySaver 永不抛异常（§4.4），结果分类驱动 albumSavedAt 与 UI 话术
    final result = await _ref
        .read(gallerySaverProvider)
        .saveVideo(path: filePath, album: albumName);
    if (result.isSaved) {
      await _ref.read(historyRepositoryProvider).markAlbumSaved(id);
      return true;
    }
    return false;
  }

  @override
  Future<bool> shareFile(String filePath) async {
    // 系统分享（share_plus；此前的自建 MethodChannel 原生侧不存在，
    // MissingPluginException 被静默吞掉导致按钮按下毫无反应）。
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(filePath)], title: AppStrings.actionShare),
      );
      // 分享面板成功拉起即算成功（用户中途取消不算失败）。
      return true;
    } catch (_) {
      return false;
    }
  }
}

final Provider<HistoryCommands> historyCommandsProvider =
    Provider<HistoryCommands>((ref) => RepoHistoryCommands(ref));

/// 历史详情实时流（drift watchById）：重存入册 / 状态演进落库后
/// 详情页即时刷新，不再停留进入时的快照（如「未保存至相册」标记）。
final historyDetailProvider =
    StreamProvider.autoDispose.family<DownloadRecord?, int>((ref, id) {
  return ref.watch(historyRepositoryProvider).watchById(id);
});

/// 历史详情页
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key, required this.item});

  final TaskItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final commands = ref.watch(historyCommandsProvider);
    // 详情随 drift 流实时刷新；行缺失/加载中回落入参快照
    final liveRecord = ref.watch(historyDetailProvider(item.id)).value;
    final view = liveRecord == null ? item : mapRecordToTaskItem(liveRecord);
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.dlSectionHistory)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(view.title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    '${view.authorName == null ? '' : '${view.authorName} · '}${formatDateTime(view.createdAt)}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${view.qualityLabel}'
                    '${view.bytesTotal == null ? '' : ' · ${formatBytes(view.bytesTotal!)}'}'
                    '${view.albumSavedAt == null ? ' · ${AppStrings.albumNotSaved}' : ''}'
                    '${view.filePath == null ? ' · ${AppStrings.fileCleaned}' : ''}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                // 播放（P1）：文件缺失（已清理/未保留沙盒副本）时禁用
                onPressed: view.filePath == null
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => PlayerScreen(filePath: view.filePath!),
                          ),
                        ),
                icon: const Icon(Icons.play_arrow),
                label: const Text(AppStrings.actionPlay),
              ),
              OutlinedButton.icon(
                onPressed: view.filePath == null
                    ? null
                    : () async {
                        final ok = await commands.shareFile(view.filePath!);
                        // 按钮存在就必须有可感知的响应：分享面板拉起失败时反馈。
                        if (!ok && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text(AppStrings.shareUnavailable)),
                          );
                        }
                      },
                icon: const Icon(Icons.share),
                label: const Text(AppStrings.actionShare),
              ),
              // 保存至相册：常驻入口（文件在即渲染，albumSavedAt 只影响文案）——
              // 用户在系统相册侧删除后仍可重新保存，兑现「ClipVault 保险库」预期。
              if (view.filePath != null)
                OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await commands.resaveToGallery(view.id, view.filePath!);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(ok ? AppStrings.resaveSucceeded : AppStrings.resaveFailed),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.save_alt),
                  label: Text(view.albumSavedAt == null
                      ? AppStrings.actionSaveToAlbum
                      : AppStrings.actionResave),
                ),
            ],
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () => _confirmDelete(context, commands, view.id),
            icon: const Icon(Icons.delete_outline),
            label: const Text(AppStrings.actionDelete),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    HistoryCommands commands,
    int id,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // 文案明示会一并删除本地视频文件（相册副本不受影响）
        content: const Text(AppStrings.deleteConfirm),
        actions: [
          // 破坏性操作的确认弹窗：取消占视觉最强位，删除用 error 前景色，
          // 不再把用户推向误删。
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(AppStrings.actionCancel)),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(AppStrings.actionDelete)),
        ],
      ),
    );
    if (confirmed ?? false) {
      await commands.delete(id);
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }
}
