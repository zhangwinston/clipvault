import 'package:clipvault/data/database.dart';
import 'package:clipvault/data/history_repository.dart';
import 'package:clipvault/data/tables.dart';
// drift 与 flutter_test(matcher) 均导出 isNull/isNotNull；本文件仅将二者
// 用作 matcher，故在 drift import 上隐藏其 SQL 谓词版本以消除 ambiguous_import。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存库构造：executor 注入（DESIGN §9-3 / §12-11）。
///
/// 说明：drift 2.35 传递依赖 sqlite3 ^3.4，经 Dart build hooks 预取预编译
/// SQLite，宿主机（Windows，本机已确认无 sqlite3.dll）无需系统级安装。
AppDatabase createDb() => AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );

/// 构造最小合法的任务插入 companion。
DownloadRecordsCompanion companion({
  int? id,
  String tweetId = '1790637656616943991',
  String status = 'queued',
  String? partPath,
  String? filePath,
  int bytesDone = 0,
  int? bytesTotal,
  String? errorCode,
}) {
  return DownloadRecordsCompanion.insert(
    tweetId: tweetId,
    variantUrl:
        'https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/1280x720/a.mp4?tag=14',
    contentType: 'mp4',
    bitrate: 2176000,
    qualityLabel: '720p (HD)',
    status: status,
    tweetJson: '{"tweetId":"$tweetId"}',
    id: id == null ? const Value.absent() : Value(id),
    partPath: partPath == null ? const Value.absent() : Value(partPath),
    filePath: filePath == null ? const Value.absent() : Value(filePath),
    bytesDone: Value(bytesDone),
    bytesTotal: bytesTotal == null ? const Value.absent() : Value(bytesTotal),
    errorCode: errorCode == null ? const Value.absent() : Value(errorCode),
  );
}

void main() {
  late AppDatabase db;
  late HistoryRepository repo;

  setUp(() {
    db = createDb();
    repo = HistoryRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('schema：download_records 表与两个索引（tweetId 单列 + (status,updatedAt) 复合）随库建立', () async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master "
          "WHERE type = 'index' AND tbl_name = 'download_records'",
        )
        .get();
    final names = rows.map((row) => row.read<String>('name')).toSet();
    expect(names, contains('idx_download_records_tweet_id'));
    expect(names, contains('idx_download_records_status_updated_at'));
  });

  test('createTask：默认值落库与字段往返', () async {
    final row = await repo.createTask(companion());
    expect(row.id, greaterThan(0));
    expect(row.bytesDone, 0);
    expect(row.speedBps, 0);
    expect(row.autoRetries, 0);
    expect(row.albumSavedAt, isNull);
    expect(row.errorCode, isNull);
    expect(row.statusEnum, DownloadStatus.queued);
    expect(row.contentType, 'mp4');
    expect(row.createdAt, isNotNull);
    expect(row.updatedAt, isNotNull);
    expect(row.tweetJson, contains('1790637656616943991'));

    final read = await repo.getById(row.id);
    expect(read, isNotNull);
    expect(read!.tweetId, '1790637656616943991');
    expect(read.statusEnum, DownloadStatus.queued);
  });

  test('状态字符串解析：严格解析抛错、容错解析返回 null', () {
    expect(parseDownloadStatus('queued'), DownloadStatus.queued);
    expect(parseDownloadStatus('canceled'), DownloadStatus.canceled);
    expect(tryParseDownloadStatus(null), isNull);
    expect(tryParseDownloadStatus('bogus'), isNull);
    expect(() => parseDownloadStatus('bogus'), throwsArgumentError);
  });

  test('upsert：携带 id 时更新既有行，未提供的列保留原值', () async {
    final created = await repo.createTask(companion(bytesTotal: 1000));
    await repo.upsert(
      companion(id: created.id, status: 'paused', bytesDone: 400),
    );
    final row = await repo.getById(created.id);
    expect(row, isNotNull);
    expect(row!.statusEnum, DownloadStatus.paused);
    expect(row.bytesDone, 400);
    expect(row.bytesTotal, 1000);
  });

  test('updateStatus：写入状态并按需清空错误码', () async {
    final created = await repo.createTask(companion());
    await repo.updateStatus(created.id, DownloadStatus.failed,
        errorCode: 'E02');
    var row = await repo.getById(created.id);
    expect(row!.statusEnum, DownloadStatus.failed);
    expect(row.errorCode, 'E02');

    await repo.updateStatus(created.id, DownloadStatus.queued);
    row = await repo.getById(created.id);
    expect(row!.statusEnum, DownloadStatus.queued);
    expect(row.errorCode, isNull);
  });

  test('updateProgress：仅覆盖显式传入的字段，其余保留', () async {
    final created = await repo.createTask(companion(bytesTotal: 1000));
    await repo.updateProgress(created.id,
        bytesDone: 250, speedBps: 512000, etaSec: 9);
    var row = await repo.getById(created.id);
    expect(row!.bytesDone, 250);
    expect(row.speedBps, 512000);
    expect(row.etaSec, 9);
    expect(row.bytesTotal, 1000);

    await repo.updateProgress(created.id, bytesDone: 600);
    row = await repo.getById(created.id);
    expect(row!.bytesDone, 600);
    expect(row.speedBps, 512000);
    expect(row.etaSec, 9);
  });

  test('albumSavedAt：标记与清除（重新保存入口依据）', () async {
    final created = await repo.createTask(companion());
    final at = DateTime.utc(2026, 9, 25, 12, 0, 0);
    await repo.markAlbumSaved(created.id, at: at);
    var row = await repo.getById(created.id);
    expect(row!.albumSavedAt, at);

    await repo.clearAlbumSaved(created.id);
    row = await repo.getById(created.id);
    expect(row!.albumSavedAt, isNull);
  });

  test('watchAll：插入与状态更新逐次触发 Stream 发射', () async {
    final expectation = expectLater(
      repo.watchAll(),
      emitsInOrder(<Matcher>[
        isEmpty,
        predicate<List<DownloadRecord>>((rows) =>
            rows.length == 1 &&
            rows.first.statusEnum == DownloadStatus.queued),
        predicate<List<DownloadRecord>>((rows) =>
            rows.length == 1 &&
            rows.first.statusEnum == DownloadStatus.running),
      ]),
    );
    await pumpEventQueue();
    final created = await repo.createTask(companion());
    await repo.updateStatus(created.id, DownloadStatus.running);
    await expectation;
  });

  test('watchByStatuses：按状态集合过滤', () async {
    final a = await repo.createTask(
        companion(status: 'completed', tweetId: '111111111111111111'));
    final b = await repo.createTask(
        companion(status: 'failed', tweetId: '222222222222222222'));

    final rows = await repo
        .watchByStatuses([DownloadStatus.completed, DownloadStatus.queued])
        .first;
    final ids = rows.map((r) => r.id).toSet();
    expect(ids, contains(a.id));
    expect(ids, isNot(contains(b.id)));
  });

  test('watchById：单条流，不存在时为 null', () async {
    final created = await repo.createTask(companion());
    final row = await repo.watchById(created.id).first;
    expect(row, isNotNull);
    expect(row!.id, created.id);
    expect(await repo.watchById(999999).first, isNull);
  });

  test('启动恢复扫描：全部未完成记录（queued/running/paused）回调重新入队，扫描只读不改', () async {
    final runningWithPart = await repo.createTask(companion(
      status: 'running',
      partPath: '/dl/a.part',
      bytesDone: 100,
      tweetId: '111111111111111111',
    ));
    final pausedWithPart = await repo.createTask(companion(
      status: 'paused',
      partPath: '/dl/b.part',
      tweetId: '222222222222222222',
    ));
    final queuedPartMissing = await repo.createTask(companion(
      status: 'queued',
      partPath: '/dl/missing.part',
      tweetId: '333333333333333333',
    ));
    final queuedNoPartPath = await repo.createTask(companion(
      status: 'queued',
      tweetId: '666666666666666666',
    ));
    final completedWithPart = await repo.createTask(companion(
      status: 'completed',
      partPath: '/dl/a.part',
      filePath: '/dl/a.mp4',
      tweetId: '444444444444444444',
    ));
    final failedWithPart = await repo.createTask(companion(
      status: 'failed',
      partPath: '/dl/b.part',
      errorCode: 'E02',
      tweetId: '555555555555555555',
    ));

    final requeued = <int>[];
    final hit = await repo.recoverOnStartup(
      onRequeue: (record) => requeued.add(record.id),
    );

    // 未完成行全部命中：仓库层不按 .part 存在性过滤（引擎 restoreFrom
    // 对 .part 缺失归零重下），排队未落盘（partPath null）的行同样
    // 回到引擎——否则将成为永不被调度的僵尸行。
    final expected = <int>[
      runningWithPart.id,
      pausedWithPart.id,
      queuedPartMissing.id,
      queuedNoPartPath.id,
    ];
    expect(requeued, unorderedEquals(expected));
    expect(hit.map((r) => r.id), unorderedEquals(expected));

    // 命中行携带续传所需的断点路径与进度。
    final resumed = hit.firstWhere((r) => r.id == runningWithPart.id);
    expect(resumed.partPath, '/dl/a.part');
    expect(resumed.bytesDone, 100);

    // 终态行不命中且保持原状态（重置状态是引擎入队流程的职责）。
    expect((await repo.getById(completedWithPart.id))!.statusEnum,
        DownloadStatus.completed);
    expect((await repo.getById(failedWithPart.id))!.statusEnum,
        DownloadStatus.failed);
  });

  test('删除：deleteById 返回被删行且幂等，deleteByTweetId 批量删除', () async {
    final a = await repo.createTask(
        companion(tweetId: '111111111111111111', partPath: '/dl/a.part'));
    await repo.createTask(companion(tweetId: '111111111111111111'));
    final c =
        await repo.createTask(companion(tweetId: '222222222222222222'));

    final removed = await repo.deleteById(a.id);
    expect(removed, isNotNull);
    expect(removed!.partPath, '/dl/a.part'); // 调用方可据此清理物理文件
    expect(await repo.getById(a.id), isNull);
    expect(await repo.deleteById(a.id), isNull);

    final removedRows = await repo.deleteByTweetId('111111111111111111');
    expect(removedRows, hasLength(1));
    final rest = await repo.getAll();
    expect(rest.map((r) => r.id), unorderedEquals(<int>[c.id]));
  });

  test('缓存统计：仅统计可清理行（completed/failed/canceled），路径去重累加真实体积，缺失文件不计入', () async {
    // completed：转正文件 + 断点文件。
    await repo.createTask(companion(
      status: 'completed',
      filePath: '/dl/a.mp4',
      partPath: '/dl/a.part',
      tweetId: '111111111111111111',
    ));
    // 另一可清理行复用同一 partPath：应按路径去重。
    await repo.createTask(companion(
      status: 'failed',
      partPath: '/dl/a.part',
      errorCode: 'E02',
      tweetId: '222222222222222222',
    ));
    // 活动行（queued/running/paused）的断点文件不可清理，不计入统计
    //（与 _cleanCacheFiles 清理口径一致，避免统计大于可清理量）。
    await repo.createTask(companion(
      status: 'paused',
      partPath: '/dl/active.part',
      tweetId: '333333333333333333',
    ));
    await repo.createTask(companion(
      status: 'queued',
      partPath: '/dl/queued.part',
      tweetId: '444444444444444444',
    ));
    // completed 但转正文件已缺失：不计入。
    await repo.createTask(companion(
      status: 'completed',
      filePath: '/dl/gone.mp4',
      tweetId: '555555555555555555',
    ));

    final sizes = <String, int>{
      '/dl/a.mp4': 24500000,
      '/dl/a.part': 4096,
      '/dl/active.part': 999999, // 活动行：不应计入
      '/dl/queued.part': 888888, // 活动行：不应计入
    };
    final stats = await repo
        .computeCacheStats(fileLengthOf: (String path) => sizes[path]);
    expect(stats.fileCount, 2); // a.mp4 + a.part（跨行去重）
    expect(stats.totalBytes, 24500000 + 4096);
  });

  test('排序稳定性：createdAt+id 倒序，进度回写（仅刷新 updatedAt）不改变行位置', () async {
    final a = await repo.createTask(companion(tweetId: '111111111111111111'));
    final b = await repo.createTask(companion(tweetId: '222222222222222222'));
    final c = await repo.createTask(companion(tweetId: '333333333333333333'));

    // 创建顺序倒序；同秒 createdAt 并列时以 id 倒序确定性打破平局。
    expect((await repo.getAll()).map((r) => r.id), <int>[c.id, b.id, a.id]);
    expect((await repo.watchAll().first).map((r) => r.id),
        <int>[c.id, b.id, a.id]);

    // 进度回写高频刷新 updatedAt：以 updatedAt 排序会把 a 顶到首位
    //（修复前行为），稳定键下行位置不得跳变。
    await repo.updateProgress(a.id, bytesDone: 100, speedBps: 2048, etaSec: 5);
    await repo.updateStatus(b.id, DownloadStatus.running);
    expect((await repo.getAll()).map((r) => r.id), <int>[c.id, b.id, a.id]);
    expect((await repo.watchAll().first).map((r) => r.id),
        <int>[c.id, b.id, a.id]);

    // watchByStatuses 同稳定排序。
    final filtered =
        await repo.watchByStatuses([DownloadStatus.running]).first;
    expect(filtered.map((r) => r.id), <int>[b.id]);
  });
}
