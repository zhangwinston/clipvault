/// 历史备份服务（DESIGN §4.7「卸载重装保留历史」方案层②编排）。
///
/// - 自动导出：订阅历史流，防抖 3 秒全量快照到 [BackupStore]（设置可关）；
/// - 自动恢复：启动时 DB 为空且备份存在 → 静默导入（重装场景零交互）；
/// - 手动恢复：设置页触发，按 (tweetId, bitrate) 去重合并。
///
/// 导入语义：
/// - 活动态（queued/running/paused）一律映射为 canceled——重装前的进行中
///   任务没有 .part 可续，保留元数据但绝不自动重下（用户可从历史重试）；
/// - 已完成行按文件名约定 {tweetId}_{bitrate}.mp4 回查相册绝对路径，
///   命中则 filePath/albumSavedAt 复活（播放/分享/重存直接可用）；
///   未命中（用户手动删过相册视频）保持 completed + filePath 置空，
///   历史元数据仍完整（离线渲染走 tweetJson 快照）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:clipvault/backup/backup_store.dart';
import 'package:clipvault/data/database.dart';
import 'package:clipvault/data/history_repository.dart';
import 'package:clipvault/data/tables.dart';

/// 备份 JSON 快照格式版本（结构变更时递增，导入侧按版本兼容）。
const int kBackupFormatVersion = 1;

/// 备份存储注入点（main 按平台装配；测试注入假实现）。
final Provider<BackupStore> backupStoreProvider =
    Provider<BackupStore>((_) => throw UnimplementedError('main 装配时覆写'));

/// 全局服务实例（main 启动装配后赋值；设置页手动操作读取；测试不经此路径）。
BackupService? activeBackupService;

class BackupService {
  BackupService({required this.repo, required this.store});

  final HistoryRepository repo;
  final BackupStore store;

  StreamSubscription<List<DownloadRecord>>? _sub;
  Timer? _debounce;
  bool _enabled = true;
  bool _exporting = false;

  /// 自动导出开关（设置页「卸载重装后保留历史」）。
  set enabled(bool value) => _enabled = value;

  /// 启动接线：先自动恢复（空库才生效），再挂历史流自动导出。
  Future<void> start({required bool autoExportEnabled}) async {
    _enabled = autoExportEnabled;
    await restoreIfEmpty();
    _sub = repo.watchAll().listen((_) => _scheduleExport());
  }

  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
  }

  // ---------------- 导出 ----------------

  void _scheduleExport() {
    if (!_enabled) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => exportNow());
  }

  /// 立即全量导出（防抖到期 / 设置页手动触发共用）。
  Future<bool> exportNow() async {
    if (_exporting) return false;
    _exporting = true;
    try {
      if (!await store.isSupported) return false;
      final rows = await repo.getAll();
      final payload = jsonEncode({
        'version': kBackupFormatVersion,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'records': [for (final r in rows) _recordToJson(r)],
      });
      final ok = await store.write(payload);
      return ok;
    } catch (_) {
      return false; // 备份失败静默降级（增强能力，绝不影响主流程）
    } finally {
      _exporting = false;
    }
  }

  Map<String, Object?> _recordToJson(DownloadRecord r) => {
        'tweetId': r.tweetId,
        'variantUrl': r.variantUrl,
        'contentType': r.contentType,
        'bitrate': r.bitrate,
        'width': r.width,
        'height': r.height,
        'qualityLabel': r.qualityLabel,
        'status': r.status,
        'bytesTotal': r.bytesTotal,
        'bytesDone': r.bytesDone,
        'errorCode': r.errorCode,
        'tweetJson': r.tweetJson,
        'albumSavedAt': r.albumSavedAt?.toUtc().toIso8601String(),
        'createdAt': r.createdAt.toUtc().toIso8601String(),
        'updatedAt': r.updatedAt.toUtc().toIso8601String(),
      };

  // ---------------- 导入 ----------------

  /// 重装自动恢复：DB 为空且备份存在 → 导入。返回导入条数（0 = 无事发生）。
  Future<int> restoreIfEmpty() async {
    try {
      if (!await store.isSupported) return 0;
      final rows = await repo.getAll();
      if (rows.isNotEmpty) return 0;
      final payload = await store.read();
      if (payload == null || payload.isEmpty) return 0;
      final n = await _importPayload(payload);
      return n;
    } catch (_) {
      return 0;
    }
  }

  /// 手动恢复：按 (tweetId, bitrate) 去重合并（设置页入口）。
  /// 返回新导入条数；-1 表示备份不存在或不可读。
  Future<int> restoreManual() async {
    try {
      if (!await store.isSupported) return -1;
      final payload = await store.read();
      if (payload == null || payload.isEmpty) return -1;
      final n = await _importPayload(payload, dedupe: true);
      return n;
    } catch (_) {
      return -1;
    }
  }

  Future<int> _importPayload(String payload, {bool dedupe = false}) async {
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, Object?>) return 0;
    final records = decoded['records'];
    if (records is! List) return 0;

    final existingKeys = <String>{};
    if (dedupe) {
      final existing = await repo.getAll();
      existingKeys.addAll(
        existing.map((r) => '${r.tweetId}:${r.bitrate}'),
      );
    }

    var imported = 0;
    for (final item in records) {
      if (item is! Map<String, Object?>) continue;
      final tweetId = item['tweetId'];
      final bitrate = item['bitrate'];
      if (tweetId is! String || bitrate is! int) continue;
      final key = '$tweetId:$bitrate';
      if (existingKeys.contains(key)) continue;
      existingKeys.add(key);

      final status = _normalizeStatus(item['status']);
      // 引擎转正命名约定：{tweetId}_{bitrate}.{contentType}（§4.3）
      final contentType = item['contentType'] as String? ?? 'mp4';
      final galleryPath =
          await store.findVideoPathByName('${tweetId}_$bitrate.$contentType');
      final savedAt = _parseDate(item['albumSavedAt']);

      await repo.createTask(DownloadRecordsCompanion.insert(
        tweetId: tweetId,
        variantUrl: item['variantUrl'] as String? ?? '',
        contentType: contentType,
        bitrate: bitrate,
        width: Value(_asInt(item['width'])),
        height: Value(_asInt(item['height'])),
        qualityLabel: item['qualityLabel'] as String? ?? '',
        status: status.name,
        bytesTotal: Value(_asInt(item['bytesTotal'])),
        bytesDone: Value(_asInt(item['bytesDone']) ?? 0),
        errorCode: Value(item['errorCode'] as String?),
        tweetJson: item['tweetJson'] as String? ?? '{}',
        albumSavedAt:
            Value(galleryPath != null ? (savedAt ?? DateTime.now().toUtc()) : null),
        filePath: Value(galleryPath),
      ));
      imported++;
    }
    return imported;
  }

  /// 活动态归 canceled（重装无 .part 可续，绝不自动重下，见类注释）。
  DownloadStatus _normalizeStatus(Object? raw) {
    if (raw is String) {
      final parsed = tryParseDownloadStatus(raw);
      if (parsed != null) {
        const active = {
          DownloadStatus.queued,
          DownloadStatus.running,
          DownloadStatus.paused,
        };
        return active.contains(parsed) ? DownloadStatus.canceled : parsed;
      }
    }
    return DownloadStatus.canceled;
  }

  static int? _asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);

  static DateTime? _parseDate(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toUtc() : null;
}
