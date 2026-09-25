import 'dart:io';

import 'package:drift/drift.dart';

import 'database.dart';
import 'tables.dart';

/// 缓存占用统计（我的 Tab「缓存占用」数据源，DESIGN §4.6）。
class CacheStats {
  const CacheStats({required this.fileCount, required this.totalBytes});

  /// 实际存在的缓存文件数（转正文件 + 断点文件去重后）。
  final int fileCount;

  /// 缓存总字节数。
  final int totalBytes;
}

/// 下载历史仓库：全部持久化读写的唯一入口（drift 之上的薄封装）。
///
/// 供下载引擎（Step 5）与 UI（Step 6）使用：
/// - Stream 查询驱动下载 Tab 实时刷新（§4.5）；
/// - [recoverOnStartup] 启动恢复扫描：未完成（queued/running/paused）记录
///   全部回调重新入队（.part 缺失由引擎归零重下，不在仓库层过滤）；
/// - [computeCacheStats] 缓存统计（仅计可清理行，与清理口径一致）；
/// - 删除仅删记录行，物理文件清理由调用方（引擎/设置页）依据返回行执行。
///
/// 时间戳读出契约：本仓库写入侧统一以 UTC 落库（[apply]/[markAlbumSaved]），
/// drift 将 DateTime 按 unix 秒（UTC 时刻）存储，但生成代码读回时映射为
/// 本地时区 DateTime；Dart 的 == 要求时刻与 UTC/本地标记均一致，本地映射
/// 会破坏「写入什么、读出什么」的往返相等（DESIGN §5.3：时间戳列以 UTC
/// 语义存储）。故所有读出路径经 [_utcAlbumSavedAt] 把 albumSavedAt 归一化
/// 为 UTC（createdAt/updatedAt 仅作展示用途，维持 drift 原映射不改）。
class HistoryRepository {
  /// 以注入的数据库构造。
  HistoryRepository(AppDatabase db) : _db = db;

  final AppDatabase _db;

  /// 读出边界归一化：albumSavedAt 统一返回 UTC 表示（同一时刻）。
  static DownloadRecord _utcAlbumSavedAt(DownloadRecord row) {
    final savedAt = row.albumSavedAt;
    if (savedAt == null || savedAt.isUtc) return row;
    return row.copyWith(albumSavedAt: Value(savedAt.toUtc()));
  }

  // ---------------- 查询 ----------------

  /// 全量记录流，按创建时间倒序、id 倒序的稳定键排序（下载 Tab 的数据源）。
  ///
  /// 进度回写会高频刷新 updatedAt（500ms 节流），若以 updatedAt 排序，
  /// 进行中分区各行会随进度互跳、无法稳定点按；createdAt 不随进度变化，
  /// 同秒并列以 id 倒序确定性地打破平局。
  Stream<List<DownloadRecord>> watchAll() {
    final query = _db.select(_db.downloadRecords)
      ..orderBy([
        (r) => OrderingTerm.desc(r.createdAt),
        (r) => OrderingTerm.desc(r.id),
      ]);
    return query.watch().map((rows) => rows.map(_utcAlbumSavedAt).toList());
  }

  /// 按状态集合过滤的记录流（进行中/队列/失败/历史分区各取所需）；
  /// 排序键与 [watchAll] 一致（稳定键，进度回写不引起行位置变化）。
  Stream<List<DownloadRecord>> watchByStatuses(
    Iterable<DownloadStatus> statuses,
  ) {
    final names = statuses.map((s) => s.name).toList();
    final query = _db.select(_db.downloadRecords)
      ..where((r) => r.status.isIn(names))
      ..orderBy([
        (r) => OrderingTerm.desc(r.createdAt),
        (r) => OrderingTerm.desc(r.id),
      ]);
    return query.watch().map((rows) => rows.map(_utcAlbumSavedAt).toList());
  }

  /// 单条记录流；id 不存在时每帧发 null。
  Stream<DownloadRecord?> watchById(int id) {
    final query = _db.select(_db.downloadRecords)
      ..where((r) => r.id.equals(id));
    return query
        .watchSingleOrNull()
        .map((row) => row == null ? null : _utcAlbumSavedAt(row));
  }

  /// 全量记录一次性读取；排序键与 [watchAll] 一致（创建时间倒序 + id 倒序）。
  Future<List<DownloadRecord>> getAll() async {
    final query = _db.select(_db.downloadRecords)
      ..orderBy([
        (r) => OrderingTerm.desc(r.createdAt),
        (r) => OrderingTerm.desc(r.id),
      ]);
    final rows = await query.get();
    return rows.map(_utcAlbumSavedAt).toList();
  }

  /// 按 id 读取单条；不存在返回 null。
  Future<DownloadRecord?> getById(int id) async {
    final query = _db.select(_db.downloadRecords)
      ..where((r) => r.id.equals(id));
    final row = await query.getSingleOrNull();
    return row == null ? null : _utcAlbumSavedAt(row);
  }

  // ---------------- 写入 ----------------

  /// 新建任务记录，返回带 id 的完整行（默认值已在表定义内生效）。
  Future<DownloadRecord> createTask(DownloadRecordsCompanion entry) async {
    final id = await _db.into(_db.downloadRecords).insert(entry);
    final query = _db.select(_db.downloadRecords)
      ..where((r) => r.id.equals(id));
    return _utcAlbumSavedAt(await query.getSingle());
  }

  /// 按 id upsert：companion 携带 [DownloadRecordsCompanion.id] 时更新该行
  /// （未提供的列保留原值），否则插入新行。
  Future<void> upsert(DownloadRecordsCompanion entry) {
    return _db.into(_db.downloadRecords).insertOnConflictUpdate(entry);
  }

  /// 通用补丁：仅更新 companion 中出现的列，并自动覆写 updatedAt。
  ///
  /// 返回受影响行数（0 = id 不存在）。
  Future<int> apply(int id, DownloadRecordsCompanion changes) {
    final merged =
        changes.copyWith(updatedAt: Value(DateTime.now().toUtc()));
    final query = _db.update(_db.downloadRecords)
      ..where((r) => r.id.equals(id));
    return query.write(merged);
  }

  /// 更新状态；[errorCode] 为 null 时清空错误码（重试/恢复场景）。
  Future<int> updateStatus(int id, DownloadStatus status, {String? errorCode}) {
    return apply(
      id,
      DownloadRecordsCompanion(
        status: Value(status.name),
        errorCode: Value(errorCode),
      ),
    );
  }

  /// 更新进度遥测；仅覆盖显式传入的字段，其余保留原值。
  Future<int> updateProgress(
    int id, {
    int? bytesDone,
    int? bytesTotal,
    int? speedBps,
    int? etaSec,
  }) {
    return apply(
      id,
      DownloadRecordsCompanion(
        bytesDone: bytesDone == null ? const Value.absent() : Value(bytesDone),
        bytesTotal:
            bytesTotal == null ? const Value.absent() : Value(bytesTotal),
        speedBps: speedBps == null ? const Value.absent() : Value(speedBps),
        etaSec: etaSec == null ? const Value.absent() : Value(etaSec),
      ),
    );
  }

  /// 标记已入相册（相册保存成功后调用；[at] 缺省为当前时间）。
  Future<int> markAlbumSaved(int id, {DateTime? at}) {
    return apply(
      id,
      DownloadRecordsCompanion(albumSavedAt: Value(at ?? DateTime.now().toUtc())),
    );
  }

  /// 清除入册标记（如权限被拒降级仅存沙盒时，恢复「重新保存」入口）。
  Future<int> clearAlbumSaved(int id) {
    return apply(id, const DownloadRecordsCompanion(albumSavedAt: Value(null)));
  }

  // ---------------- 启动恢复（DESIGN §4.5） ----------------

  /// 启动恢复扫描：状态为未完成（queued/running/paused）的全部记录，
  /// 逐条经 [onRequeue] 回调交回下载引擎重新入队。返回全部命中记录。
  ///
  /// .part 是否存在不在本层过滤：引擎 restoreFrom 已按「.part 仍存在 →
  /// 以文件实际长度续传；.part 丢失/partPath 尚为 null → bytesDone 归零
  /// 重下」收敛。若在此按文件存在性过滤，排队中（partPath 未落库）或断点
  /// 文件被清的记录将永远不会回到引擎，成为 UI 可见但永不被调度的
  /// 僵尸行。
  ///
  /// 本方法只读不改：DB 内状态翻转（如 running→queued）由引擎入队流程
  /// 经 [updateStatus] 落库。
  Future<List<DownloadRecord>> recoverOnStartup({
    required void Function(DownloadRecord record) onRequeue,
  }) async {
    const unfinished = [
      DownloadStatus.queued,
      DownloadStatus.running,
      DownloadStatus.paused,
    ];
    final names = unfinished.map((s) => s.name).toList();
    final query = _db.select(_db.downloadRecords)
      ..where((r) => r.status.isIn(names));
    final rows = (await query.get()).map(_utcAlbumSavedAt).toList();
    for (final row in rows) {
      onRequeue(row);
    }
    return rows;
  }

  // ---------------- 删除 ----------------

  /// 删除单条记录，返回被删行（供调用方清理物理文件）；不存在返回 null。
  Future<DownloadRecord?> deleteById(int id) async {
    final row = await getById(id);
    if (row == null) return null;
    final query = _db.delete(_db.downloadRecords)
      ..where((r) => r.id.equals(id));
    await query.go();
    return row;
  }

  /// 删除某推文的全部记录，返回被删各行。
  Future<List<DownloadRecord>> deleteByTweetId(String tweetId) async {
    final select = _db.select(_db.downloadRecords)
      ..where((r) => r.tweetId.equals(tweetId));
    final rows = (await select.get()).map(_utcAlbumSavedAt).toList();
    final delete = _db.delete(_db.downloadRecords)
      ..where((r) => r.tweetId.equals(tweetId));
    await delete.go();
    return rows;
  }

  // ---------------- 缓存统计（DESIGN §4.6） ----------------

  /// 统计沙盒缓存占用：仅统计可清理行（completed/failed/canceled）的
  /// 转正文件（filePath）与断点文件（partPath），与设置页「一键清理」
  /// 的口径一致（main.dart _cleanCacheFiles 同规则过滤）；未完成行
  /// （queued/running/paused）的断点文件是活动任务的进度，不可清理，
  /// 也不计入，避免「统计大于可清理量」的口径漂移。路径去重后累加
  /// 真实体积；缺失文件不计入。
  ///
  /// [fileLengthOf] 返回 null 表示文件不存在；默认实现走真实文件系统，
  /// 测试注入即可离线断言。
  Future<CacheStats> computeCacheStats({
    int? Function(String path)? fileLengthOf,
  }) async {
    const cleanable = {
      DownloadStatus.completed,
      DownloadStatus.failed,
      DownloadStatus.canceled,
    };
    final lengthOf = fileLengthOf ?? _fileLengthOrNull;
    final rows = await _db.select(_db.downloadRecords).get();
    final seen = <String>{};
    var fileCount = 0;
    var totalBytes = 0;
    for (final row in rows) {
      if (!cleanable.contains(row.statusEnum)) continue;
      for (final path in [row.filePath, row.partPath]) {
        if (path == null || path.isEmpty || !seen.add(path)) continue;
        final length = lengthOf(path);
        if (length != null) {
          fileCount += 1;
          totalBytes += length;
        }
      }
    }
    return CacheStats(fileCount: fileCount, totalBytes: totalBytes);
  }

  int? _fileLengthOrNull(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.lengthSync();
  }
}
