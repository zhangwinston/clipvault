/// 历史备份服务测试（DESIGN §4.7）：
/// 全部离线——内存 drift 仓库 + 假 BackupStore，不触平台通道/磁盘公共区。
library;

import 'dart:convert';

import 'package:drift/drift.dart' hide Column, isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/backup/backup_service.dart';
import 'package:clipvault/backup/backup_store.dart';
import 'package:clipvault/data/database.dart';
import 'package:clipvault/data/history_repository.dart';

/// 假存储：内存字符串 + 可编程的相册路径回查。
class FakeBackupStore implements BackupStore {
  String? saved;
  final Map<String, String> galleryPaths;

  FakeBackupStore({this.galleryPaths = const {}});

  @override
  Future<bool> get isSupported async => true;

  @override
  Future<bool> write(String json) async {
    saved = json;
    return true;
  }

  @override
  Future<String?> read() async => saved;

  @override
  Future<String?> findVideoPathByName(String name) async => galleryPaths[name];
}

/// 每用例独立的内存仓库（drift 内存库不可复用；沿 db.close() 拆卸惯例）。
({HistoryRepository repo, AppDatabase db}) _newRepo() {
  final db = AppDatabase(DatabaseConnection(
    NativeDatabase.memory(),
    closeStreamsSynchronously: true,
  ));
  return (repo: HistoryRepository(db), db: db);
}

Future<DownloadRecord> _insert(
  HistoryRepository repo, {
  required String tweetId,
  int bitrate = 2176000,
  String status = 'completed',
  String? filePath,
  DateTime? albumSavedAt,
}) {
  return repo.createTask(DownloadRecordsCompanion.insert(
    tweetId: tweetId,
    variantUrl: 'https://video.example/$tweetId.mp4',
    contentType: 'mp4',
    bitrate: bitrate,
    qualityLabel: '720p (HD)',
    status: status,
    tweetJson: '{"author":"测试作者"}',
    filePath: Value(filePath),
    albumSavedAt: Value(albumSavedAt),
  ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('导出→清空库→自动恢复：完整往返，相册命中时 filePath/albumSavedAt 复活',
      () async {
    final src = _newRepo();
    addTearDown(src.db.close);
    final store = FakeBackupStore(
      galleryPaths: {'1790637656616943991_2176000.mp4': '/gallery/1790.mp4'},
    );
    final svc = BackupService(repo: src.repo, store: store);

    await _insert(src.repo,
        tweetId: '1790637656616943991', albumSavedAt: DateTime.utc(2026, 9, 25));
    await _insert(src.repo, tweetId: '1790637656616944000');

    expect(await svc.exportNow(), isTrue);
    final payload = store.saved!;
    expect((jsonDecode(payload) as Map<String, Object?>)['version'], 1);

    // 模拟卸载重装：全新空库 + 同一备份文件
    final dst = _newRepo();
    addTearDown(dst.db.close);
    final n = await BackupService(repo: dst.repo, store: store).restoreIfEmpty();
    expect(n, 2);

    final rows = await dst.repo.getAll();
    expect(rows, hasLength(2));
    final hit = rows.singleWhere((r) => r.tweetId == '1790637656616943991');
    expect(hit.filePath, '/gallery/1790.mp4'); // 相册回查命中
    expect(hit.albumSavedAt, isNotNull);
    final miss = rows.singleWhere((r) => r.tweetId == '1790637656616944000');
    expect(miss.filePath, isNull); // 未命中：元数据恢复，路径置空
    expect(miss.albumSavedAt, isNull);
  });

  test('活动态导入一律归 canceled（绝不自动重下），终态原样保留', () async {
    final src = _newRepo();
    addTearDown(src.db.close);
    final store = FakeBackupStore();
    await _insert(src.repo, tweetId: '1111111111111111111', status: 'running');
    await _insert(src.repo, tweetId: '2222222222222222222', status: 'paused');
    await _insert(src.repo, tweetId: '3333333333333333333', status: 'failed');
    await _insert(src.repo, tweetId: '4444444444444444444', status: 'canceled');
    await BackupService(repo: src.repo, store: store).exportNow();

    final dst = _newRepo();
    addTearDown(dst.db.close);
    await BackupService(repo: dst.repo, store: store).restoreIfEmpty();

    final statuses = {
      for (final r in await dst.repo.getAll()) r.tweetId: r.status,
    };
    expect(statuses['1111111111111111111'], 'canceled');
    expect(statuses['2222222222222222222'], 'canceled');
    expect(statuses['3333333333333333333'], 'failed');
    expect(statuses['4444444444444444444'], 'canceled');
  });

  test('库非空时自动恢复为 no-op；手动恢复按 (tweetId,bitrate) 去重', () async {
    final store = FakeBackupStore();
    final src = _newRepo();
    addTearDown(src.db.close);
    await _insert(src.repo, tweetId: '1111111111111111111');
    await _insert(src.repo, tweetId: '2222222222222222222');
    await BackupService(repo: src.repo, store: store).exportNow();

    // 库非空 → 自动恢复不导入
    final dst = _newRepo();
    addTearDown(dst.db.close);
    await _insert(dst.repo, tweetId: '1111111111111111111');
    final auto = BackupService(repo: dst.repo, store: store);
    expect(await auto.restoreIfEmpty(), 0);
    expect((await dst.repo.getAll()).length, 1);

    // 手动恢复 → 只合并缺失的
    expect(await auto.restoreManual(), 1);
    expect(await dst.repo.getAll(), hasLength(2));
  });

  test('备份缺失/损坏时静默降级（返回 0 / -1，绝不抛）', () async {
    final t = _newRepo();
    addTearDown(t.db.close);
    final empty = BackupService(repo: t.repo, store: FakeBackupStore());
    expect(await empty.restoreIfEmpty(), 0);
    expect(await empty.restoreManual(), -1);

    final corrupt = FakeBackupStore()..saved = 'not-a-json{{{';
    final svc = BackupService(repo: t.repo, store: corrupt);
    expect(await svc.restoreIfEmpty(), 0);
    // 损坏 = 「不可读」→ restoreManual 归入 -1 语义（区别于 0=已去重无新增）
    expect(await svc.restoreManual(), -1);
  });
}
