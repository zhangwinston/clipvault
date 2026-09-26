/// 应用入口（DESIGN §③ lib/main.dart）：
/// - 显式 [ProviderContainer]（生产 overrides + 启动恢复 bootstrap）；
/// - 启动恢复：仓库扫描未完成（queued/running/paused）的全部记录 →
///   引擎重新入队（.part 缺失由引擎归零重下，§4.5）；
/// - 全局 ImageCache 30MB 上限（§5.5 / §9-11）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/app.dart';
import 'package:clipvault/backup/backup_service.dart';
import 'package:clipvault/backup/backup_store.dart';
import 'package:clipvault/data/history_repository.dart';
import 'package:clipvault/data/tables.dart';
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
          sizeBytes: () async => (await repo.computeCacheStats()).totalBytes,
          detailedStats: () async {
            final s = await repo.computeCacheStats();
            return (fileCount: s.fileCount, totalBytes: s.totalBytes);
          },
          cleaner: () => _cleanCacheFiles(repo),
        );
      }),
      // 历史备份存储：Android 走 MediaStore 公共 Downloads（跨卸载保留），
      // 其余平台 Documents（iOS「文件」App 可见 + iCloud 备份，§4.7）
      backupStoreProvider.overrideWith(
        (ref) => defaultBackupStoreForPlatform(defaultTargetPlatform),
      ),
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
/// 不按 .part 存在性过滤），交命令层分流（P0-2 修复）：
/// 仅 Wi-Fi 偏好开启且当前非 Wi-Fi → 挂起等待 Wi-Fi（与运行时同一语义），
/// 其余交引擎断点续传——.part 缺失/排队未落盘的记录由引擎归零重下，
/// 不会遗留永不被调度的僵尸行，也不会重启即在蜂窝网络直接开跑。
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
    final settingsSub = container.listen(
      settingsControllerProvider,
      (_, next) => maybeRelease(next),
    );
    await released.future;
    settingsSub.close();

    final repo = container.read(historyRepositoryProvider);

    // 历史备份（§4.7）：重装场景先静默恢复（空库才生效），再挂自动导出。
    // 必须在引擎恢复扫描之前——导入的记录含活动态映射的 canceled，
    // 不参与重下；已存在记录时 restoreIfEmpty 为 no-op。
    final settings = container.read(settingsControllerProvider).value;
    final backup = BackupService(
      repo: repo,
      store: container.read(backupStoreProvider),
    );
    backup.enabled = settings?.backupHistory ?? true;
    await backup.start(autoExportEnabled: settings?.backupHistory ?? true);
    activeBackupService = backup;
    // 设置页关闭开关 → 停自动导出（已生成的备份文件保留）
    container.listen<bool>(
      backupHistoryFlagProvider,
      (_, next) => backup.enabled = next,
      fireImmediately: false,
    );

    final commands = container.read(downloadCommandsProvider);
    final recovered = await repo.recoverOnStartup(onRequeue: (_) {});
    await restoreDownloadRecords(commands, recovered);
  } catch (_) {
    // 恢复失败不阻断启动（下次启动仍可恢复）
  }
}

/// 仓库缓存适配（生产；测试默认用 EmptyCacheStore）
class RepositoryCacheStore implements CacheStore {
  RepositoryCacheStore({
    required Future<int> Function() sizeBytes,
    required this.cleaner,
    this.detailedStats,
  }) : _sizeBytesFn = sizeBytes;

  final Future<int> Function() _sizeBytesFn;
  final Future<void> Function() cleaner;

  /// 精确统计（文件数 + 字节数），供清理确认弹窗列明实际影响。
  final Future<({int fileCount, int totalBytes})> Function()? detailedStats;

  @override
  Future<int> sizeBytes() => _sizeBytesFn();

  @override
  Future<({int fileCount, int totalBytes})> stats() async {
    if (detailedStats != null) return detailedStats!();
    return (fileCount: 0, totalBytes: await _sizeBytesFn());
  }

  @override
  Future<void> clear() => cleaner();
}

/// 清理沙盒缓存文件（转正 + .part），记录行保留（历史元数据仍在，
/// needsResave/离线渲染不依赖文件存在），但行的 filePath/partPath 置空——
/// 否则会遗留「播放必报错 / 重存必失败」的死入口（P0-4 修复）。
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
    var deletedAny = false;
    for (final path in [row.filePath, row.partPath]) {
      if (path == null || path.isEmpty) continue;
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          deletedAny = true;
        }
      } catch (_) {
        // 单文件清理失败继续（占用/权限）
      }
    }
    if (deletedAny || row.filePath != null || row.partPath != null) {
      try {
        await repo.clearFilePaths(row.id);
      } catch (_) {
        // 路径清空失败容忍（下次清理再收敛）
      }
    }
  }
}
