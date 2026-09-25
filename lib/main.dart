/// 应用入口（DESIGN §③ lib/main.dart）：
/// - 显式 [ProviderContainer]（生产 overrides + 启动恢复 bootstrap）；
/// - 启动恢复：仓库扫描未完成（queued/running/paused）的全部记录 →
///   引擎重新入队（.part 缺失由引擎归零重下，§4.5）；
/// - 全局 ImageCache 30MB 上限（§5.5 / §9-11）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/app.dart';
import 'package:clipvault/data/history_repository.dart';
import 'package:clipvault/data/tables.dart';
import 'package:clipvault/download/download_task.dart' as dt;
import 'package:clipvault/settings/settings_controller.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';

/// 缩略图缓存上限（字节）：30MB（DESIGN §9-11）
const int kImageCacheMaxBytes = 30 * 1024 * 1024;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _capImageCache();
  final container = ProviderContainer(
    overrides: [
      // 生产侧缓存统计/清理：复用历史仓库 + 物理文件清理（S4 约定：
      // 删除仅删记录行，物理文件清理由调用方依据返回行执行）
      cacheStoreProvider.overrideWith((ref) {
        final repo = ref.watch(historyRepositoryProvider);
        return RepositoryCacheStore(
          stats: () async => (await repo.computeCacheStats()).totalBytes,
          cleaner: () => _cleanCacheFiles(repo),
        );
      }),
    ],
  );
  runApp(UncontrolledProviderScope(
    container: container,
    child: const XdownApp(),
  ));
  // 启动恢复（不阻塞首帧）：未完成记录全部 → 引擎重新入队（§4.5）
  _bootstrapRecovery(container);
}

void _capImageCache() {
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSizeBytes = kImageCacheMaxBytes;
  imageCache.maximumSize = 2000;
}

/// 启动恢复装配（§4.5）：
/// recoverOnStartup 只读扫描全部未完成记录（queued/running/paused，
/// 不按 .part 存在性过滤），映射为引擎任务（id 约定 rec_{rowId}）后交
/// 引擎断点续传——.part 缺失/排队未落盘的记录由引擎归零重下，不会遗留
/// 永不被调度的僵尸行。
Future<void> _bootstrapRecovery(ProviderContainer container) async {
  try {
    // 免责声明门禁（§8.3 版本化重弹）：未同意（含版本升级重弹）前不恢复
    // 任何下载任务——避免用户尚未同意条款时 App 自动发起网络请求。
    // 已同意场景（常规启动）在初值检查时立即放行，无额外延迟。
    final released = Completer<void>();
    void maybeRelease(AsyncValue<SettingsState> s) {
      final v = s.value;
      if (v != null && !v.needsDisclaimer && !released.isCompleted) {
        released.complete();
      }
    }

    maybeRelease(container.read(settingsControllerProvider));
    final sub = container.listen(
      settingsControllerProvider,
      (_, next) => maybeRelease(next),
    );
    await released.future;
    sub.close();

    final engine = container.read(downloadEngineProvider);
    final repo = container.read(historyRepositoryProvider);
    final recovered = await repo.recoverOnStartup(onRequeue: (_) {});
    final tasks = <dt.DownloadTask>[
      for (final r in recovered)
        dt.DownloadTask(
          id: EngineDownloadCommands.engineIdOf(r.id),
          tweetId: r.tweetId,
          variantUrl: r.variantUrl,
          contentType: r.contentType,
          bitrate: r.bitrate,
          qualityLabel: r.qualityLabel,
          width: r.width,
          height: r.height,
          status: _engineStatusOf(r.status),
          bytesDone: r.bytesDone,
          bytesTotal: r.bytesTotal,
          filePath: r.filePath,
          partPath: r.partPath,
          tweetJson: _decodeSnapshot(r.tweetJson),
          createdAt: r.createdAt,
        ),
    ];
    await engine.restoreFrom(tasks);
  } catch (_) {
    // 恢复失败不阻断启动（下次启动仍可恢复）
  }
}

/// 记录状态串 → 引擎侧枚举（两侧枚举同名；未知回落 queued）
dt.DownloadStatus _engineStatusOf(String name) {
  for (final s in dt.DownloadStatus.values) {
    if (s.name == name) return s;
  }
  return dt.DownloadStatus.queued;
}

Map<String, Object?>? _decodeSnapshot(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, Object?> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// 仓库缓存适配（生产；测试默认用 EmptyCacheStore）
class RepositoryCacheStore implements CacheStore {
  RepositoryCacheStore({required this.stats, required this.cleaner});

  final Future<int> Function() stats;
  final Future<void> Function() cleaner;

  @override
  Future<int> sizeBytes() => stats();

  @override
  Future<void> clear() => cleaner();
}

/// 清理沙盒缓存文件（转正 + .part），记录行保留（历史元数据仍在，
/// needsResave/离线渲染不依赖文件存在）。
///
/// 仅处理已终结行（completed/failed/canceled）的文件：未完成行
/// （queued/running/paused）的 .part 是活动任务的断点进度，删除会使
/// 恢复时进度归零、进行中清理更会引发转正失败，一律跳过。口径与
/// [HistoryRepository.computeCacheStats] 一致（统计即全部可清理）。
Future<void> _cleanCacheFiles(HistoryRepository repo) async {
  final rows = await repo.getAll();
  const cleanable = <DownloadStatus>{
    DownloadStatus.completed,
    DownloadStatus.failed,
    DownloadStatus.canceled,
  };
  for (final row in rows) {
    final status = tryParseDownloadStatus(row.status);
    if (status == null || !cleanable.contains(status)) continue;
    for (final path in [row.filePath, row.partPath]) {
      if (path == null || path.isEmpty) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 单文件清理失败继续（占用/权限）
      }
    }
  }
}
