/// 历史备份服务测试（DESIGN §4.7）：
/// 全部离线——内存 drift 仓库 + 假 BackupStore，不触平台通道/磁盘公共区。
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide Column, isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/backup/backup_service.dart';
import 'package:clipvault/backup/backup_store.dart';
import 'package:clipvault/data/database.dart';
import 'package:clipvault/data/history_repository.dart';

/// 假存储：内存字符串 + 可编程的相册路径回查。
///
/// 可见性建模（对应作用域存储语义）：
/// - [galleryPaths]：自有贡献，无权恒可见（正常/覆盖安装场景）；
/// - [orphanPaths]：重装孤儿，授权相册读权限后才可见；
/// - [grantPermission]：权限弹窗的用户应答；请求次数记入
///   [permissionRequests]（断言「幸福路径不弹窗」用）。
class FakeBackupStore implements BackupStore {
  String? saved;

  // implements 下抽象类的具体字段仅是接口（getter/setter 对），需自备存储
  @override
  Object? lastError;

  /// 写入次数（并发共享用例断言「在途复用不重复写」）
  int writes = 0;

  /// 可选写入门闩（非 null 时 write 阻塞至完成——构造在途窗口用）
  Completer<void>? writeGate;

  /// 模拟写入失败（诊断透出用例）
  bool failWrite = false;

  /// SAF 兜底通道的模拟载荷（非 null 时 pickAndRead 返回它）
  String? pickPayload;
  final Map<String, String> galleryPaths;
  final Map<String, String> orphanPaths;
  final bool grantPermission;
  int permissionRequests = 0;
  bool _granted = false;

  FakeBackupStore({
    this.galleryPaths = const {},
    this.orphanPaths = const {},
    this.grantPermission = false,
  });

  @override
  Future<bool> get isSupported async => true;

  @override
  Future<bool> write(String json) async {
    final gate = writeGate;
    if (gate != null) await gate.future;
    writes++;
    saved = json;
    return !failWrite;
  }

  @override
  Future<String?> read() async => saved;

  @override
  Future<String?> findVideoPathByName(String name) async {
    final own = galleryPaths[name];
    if (own != null) return own;
    return _granted ? orphanPaths[name] : null;
  }

  @override
  Future<String?> pickAndRead() async => pickPayload;

  @override
  Future<bool> requestVideoReadPermission() async {
    permissionRequests++;
    _granted = _granted || grantPermission;
    return _granted;
  }
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

  test('直读失败 → SAF 选择器兜底导入（跨卸载所有权断裂场景）', () async {
    // 导出侧
    final src = _newRepo();
    addTearDown(src.db.close);
    final exportStore = FakeBackupStore();
    await _insert(src.repo, tweetId: '5555555555555555555');
    await BackupService(repo: src.repo, store: exportStore).exportNow();
    final payload = exportStore.saved!;

    // 重装侧：直读 null（所有权不归属新安装），SAF 兜底返回同一载荷
    final dst = _newRepo();
    addTearDown(dst.db.close);
    final store = FakeBackupStore()..pickPayload = payload;
    final n = await BackupService(repo: dst.repo, store: store).restoreManual();
    expect(n, 1);
    expect(await dst.repo.getAll(), hasLength(1));
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

  /// 单条已完成记录的备份载荷（2026-10-05 视频路径复活用例）。
  String payloadWithCompleted(String tweetId) => jsonEncode({
        'version': 1,
        'exportedAt': '2026-10-05T00:00:00Z',
        'records': [
          {
            'tweetId': tweetId,
            'variantUrl': 'https://video.example/$tweetId.mp4',
            'contentType': 'mp4',
            'bitrate': 2176000,
            'qualityLabel': '720p (HD)',
            'status': 'completed',
            'bytesTotal': 1024,
            'bytesDone': 1024,
            'tweetJson': '{"author":"测试作者"}',
            'albumSavedAt': '2026-10-04T00:00:00Z',
          },
        ],
      });

  test('重装恢复（回归 2026-10-05）：SAF 兜底导入 + 授权后孤儿视频路径复活',
      () async {
    final t = _newRepo();
    addTearDown(t.db.close);
    final store = FakeBackupStore(
      orphanPaths: {
        '1790637656616943998_2176000.mp4':
            '/storage/emulated/0/Movies/ClipVault/1790637656616943998_2176000.mp4',
      },
      grantPermission: true,
    )..pickPayload = payloadWithCompleted('1790637656616943998');

    final n = await BackupService(repo: t.repo, store: store).restoreManual();

    expect(n, 1);
    final row = (await t.repo.getAll()).single;
    expect(row.filePath, contains('Movies/ClipVault'), reason: '授权后孤儿视频复活');
    expect(row.albumSavedAt, isNotNull);
    expect(store.permissionRequests, 1, reason: '无权回查未命中才弹一次');
  });

  test('重装恢复：用户拒绝相册权限 → 元数据完整导入，路径留空（可后再试）',
      () async {
    final t = _newRepo();
    addTearDown(t.db.close);
    final store = FakeBackupStore(grantPermission: false)
      ..pickPayload = payloadWithCompleted('1790637656616943999');

    final n = await BackupService(repo: t.repo, store: store).restoreManual();

    expect(n, 1);
    final row = (await t.repo.getAll()).single;
    expect(row.status, 'completed');
    expect(row.filePath, isNull, reason: '拒绝授权：路径不复活');
    expect(row.tweetJson, contains('测试作者'), reason: '元数据仍完整');
    expect(store.permissionRequests, 1);
  });

  test('幸福路径不弹权限：自有贡献视频无权可见，命中即返', () async {
    final t = _newRepo();
    addTearDown(t.db.close);
    final store = FakeBackupStore(
      galleryPaths: {
        '1790637656616944000_2176000.mp4':
            '/storage/emulated/0/Movies/ClipVault/1790637656616944000_2176000.mp4',
      },
    )..pickPayload = payloadWithCompleted('1790637656616944000');

    final n = await BackupService(repo: t.repo, store: store).restoreManual();

    expect(n, 1);
    expect((await t.repo.getAll()).single.filePath, contains('Movies/ClipVault'));
    expect(store.permissionRequests, 0, reason: '全部命中即不得弹权限窗');
  });

  test('并发导出共享同一轮在途 Future（手动点击撞上自动导出不再判失败）', () async {
    final t = _newRepo();
    addTearDown(t.db.close);
    final store = FakeBackupStore()..writeGate = Completer<void>();
    final svc = BackupService(repo: t.repo, store: store);
    await _insert(t.repo, tweetId: '1790637656616943991');

    // 第一轮在途（写入被门闩挂住）时第二次触发：复用同一轮而非失败
    final r1 = svc.exportNow();
    final r2 = svc.exportNow();
    store.writeGate!.complete();
    expect(await r1, isTrue);
    expect(await r2, isTrue);
    expect(store.writes, 1, reason: '在途复用，不重复写');

    // 完成后单飞引用已清：新触发真正执行新一轮
    expect(await svc.exportNow(), isTrue);
    expect(store.writes, 2);
  });

  test('失败原因透出：lastExportError 携带根因（诊断上 UI 用）', () async {
    final t = _newRepo();
    addTearDown(t.db.close);
    final store = FakeBackupStore()..failWrite = true;
    final svc = BackupService(repo: t.repo, store: store);
    await _insert(t.repo, tweetId: '1790637656616943991');

    expect(await svc.exportNow(), isFalse);
    expect(svc.lastExportError, isNotNull);
    // 透出后最近一次成功会清空
    store.failWrite = false;
    expect(await svc.exportNow(), isTrue);
    expect(svc.lastExportError, isNull);
  });
}
