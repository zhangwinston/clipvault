// 历史命令与详情页测试（review C8/C9）：
// - C8：RepoHistoryCommands.delete 接收 deleteById 返回行，best-effort 删除
//   行内 filePath/partPath 物理文件（此前只删行，文件成缓存不可见孤儿）；
// - C9：历史详情页随 drift watchById 实时流刷新（重存入册后
//   「未保存至相册」标记即时消失，不再停留进入时快照）。

import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/data/database.dart';
import 'package:clipvault/data/history_repository.dart';
import 'package:clipvault/data/tables.dart' show DownloadStatus;
import 'package:clipvault/download/download_engine.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';
import 'package:clipvault/ui/history/history_screen.dart';

AppDatabase createDb() => AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );

class _FakeHistoryCommands implements HistoryCommands {
  @override
  Future<void> delete(int id) async {}

  @override
  Future<bool> resaveToGallery(int id, String filePath) async => true;

  @override
  Future<void> shareFile(String filePath) async {}
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

  test('删除历史：物理文件（转正 + .part）随行一并清理（review C8）', () async {
    // 临时目录伪造两个物理文件
    final tmp = await Directory.systemTemp.createTemp('xdown_history_test');
    addTearDown(() => tmp.delete(recursive: true));
    final mp4 = File('${tmp.path}${Platform.pathSeparator}t_2176000.mp4');
    final part = File('${tmp.path}${Platform.pathSeparator}t_2176000.part');
    await mp4.writeAsString('final');
    await part.writeAsString('partial');

    final row = await repo.createTask(DownloadRecordsCompanion.insert(
      tweetId: '1790637656616943991',
      variantUrl: 'https://video.twimg.com/x.mp4',
      contentType: 'mp4',
      bitrate: 2176000,
      qualityLabel: '720p (HD)',
      status: DownloadStatus.completed.name,
      tweetJson: '{"tweetId":"1790637656616943991"}',
      filePath: Value(mp4.path),
      partPath: Value(part.path),
    ));

    // 生产命令装配：仓库 + 裸引擎（无任务，仅走「引擎未知 id」分支）
    final container = ProviderContainer(overrides: [
      historyRepositoryProvider.overrideWithValue(repo),
      downloadEngineProvider.overrideWith((ref) => DownloadEngine()),
    ]);
    addTearDown(container.dispose);

    await container.read(historyCommandsProvider).delete(row.id);

    expect(await repo.getById(row.id), isNull); // 行已删
    expect(await mp4.exists(), isFalse); // 转正文件已删
    expect(await part.exists(), isFalse); // 断点文件已删
  });

  test('删除历史：文件已被外部清理时容错（不抛异常、行仍删除）', () async {
    final row = await repo.createTask(DownloadRecordsCompanion.insert(
      tweetId: '1790637656616943991',
      variantUrl: 'https://video.twimg.com/x.mp4',
      contentType: 'mp4',
      bitrate: 2176000,
      qualityLabel: '720p (HD)',
      status: DownloadStatus.completed.name,
      tweetJson: '{"tweetId":"1790637656616943991"}',
      filePath: Value('Z:/nonexistent/dir/t_2176000.mp4'),
    ));

    final container = ProviderContainer(overrides: [
      historyRepositoryProvider.overrideWithValue(repo),
      downloadEngineProvider.overrideWith((ref) => DownloadEngine()),
    ]);
    addTearDown(container.dispose);

    await container.read(historyCommandsProvider).delete(row.id);
    expect(await repo.getById(row.id), isNull);
  });

  testWidgets('详情页随 drift 流刷新：入册后「未保存至相册」即时消失（review C9）', (tester) async {
    final row = await repo.createTask(DownloadRecordsCompanion.insert(
      tweetId: '1790637656616943991',
      variantUrl: 'https://video.twimg.com/x.mp4',
      contentType: 'mp4',
      bitrate: 2176000,
      qualityLabel: '720p (HD)',
      status: DownloadStatus.completed.name,
      tweetJson:
          '{"tweetId":"1790637656616943991","userName":"作者","text":"详情刷新测试"}',
      filePath: Value('/data/downloads/t_2176000.mp4'),
    ));
    final item = mapRecordToTaskItem(row);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          historyRepositoryProvider.overrideWithValue(repo),
          historyCommandsProvider.overrideWith((ref) => _FakeHistoryCommands()),
        ],
        child: MaterialApp(home: HistoryScreen(item: item)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining(AppStrings.albumNotSaved), findsOneWidget);
    expect(find.text(AppStrings.actionResave), findsOneWidget);

    // 落库入册（生产路径由 RepoHistoryCommands.resaveToGallery 写入）
    await repo.markAlbumSaved(row.id);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining(AppStrings.albumNotSaved), findsNothing);
    expect(find.text(AppStrings.actionResave), findsNothing);
  });
}
