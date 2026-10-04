/// 跨重启持久化生命周期契约（回归 2026-10-04：用户报告失败记录在
/// 手工清理 App 重启后「消失」）：
/// 真文件 DB 两会话——会话 1 任务失败落库 → 关库（等价进程终止，已提交
/// 事务必达）→ 会话 2 重开同一文件：failed 行仍可见（列表是 DB 驱动流）、
/// 恢复扫描命中、经 restoreRecords 登记引擎后「一键重试」可完成。
///
/// 本用例钉死持久层契约：failed 记录一经写入，重启不会消失。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/data/database.dart';
import 'package:clipvault/data/history_repository.dart';
import 'package:clipvault/data/tables.dart' show DownloadStatus;
import 'package:clipvault/download/download_engine.dart';
import 'package:clipvault/download/download_task.dart' as dt;
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.fetchHandler);
  final Future<ResponseBody> Function(RequestOptions options) fetchHandler;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      fetchHandler(options);

  @override
  void close({bool force = false}) {}
}

VideoVariant _variant(int bitrate) => VideoVariant(
      contentType: VariantContentType.mp4,
      bitrate: bitrate,
      url: 'https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/1280x720/x.mp4',
      width: 1280,
      height: 720,
      estimatedBytes: bitrate * 90000 ~/ 8000,
    );

void main() {
  late Directory tmpDir;
  late File dbFile;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('xdown_lifecycle_');
    dbFile = File('${tmpDir.path}${Platform.pathSeparator}xdown.db');
  });

  tearDown(() async {
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {
      // Windows 句柄延迟释放容忍
    }
  });

  AppDatabase openDb() => AppDatabase(DatabaseConnection(
      NativeDatabase(dbFile), closeStreamsSynchronously: true));

  test('失败记录跨重启持久可见：会话1失败落库 → 会话2可见 + 可重试完成',
      () async {
    final body = Uint8List.fromList(
        List<int>.generate(8 * 1024, (i) => i & 0xFF));

    // ---- 会话 1：下载失败（404 permanent 秒败）→ failed 行落库 ----
    int rowId;
    {
      final db = openDb();
      final repo = HistoryRepository(db);
      Future<ResponseBody> notFound(RequestOptions o) async =>
          ResponseBody(
              Stream<Uint8List>.fromIterable(const <Uint8List>[]), 404);
      final engine = DownloadEngine(
        dio: Dio()..httpClientAdapter = _StubAdapter(notFound),
        downloadDir: tmpDir,
        store: RepoDownloadStore(repo),
      );
      final commands = EngineDownloadCommands(engine, repo);
      final result = await commands.enqueue(
        tweetId: '1790637656616943996',
        variant: _variant(2176000),
        tweetJson: '{"tweetId":"1790637656616943996"}',
      );
      expect(result, DownloadEnqueueResult.enqueued);
      rowId = (await repo.getAll()).single.id;

      // 轮询至 DB 行落为 failed（upsert 为 fire-and-forget 异步回写）
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        final row = await repo.getById(rowId);
        if (row?.status == DownloadStatus.failed.name) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect((await repo.getById(rowId))!.status,
          DownloadStatus.failed.name, reason: '会话1：失败状态已持久化');

      await engine.dispose();
      await db.close(); // 模拟进程终止（已提交事务必达磁盘）
    }

    // ---- 会话 2：重开同一 DB 文件（App 重启）----
    {
      final db = openDb();
      final repo = HistoryRepository(db);

      // 1) 失败记录可见（下载页列表 = watchAll/getAll 全量 DB 驱动）
      final rows = await repo.getAll();
      expect(rows, hasLength(1));
      expect(rows.first.status, DownloadStatus.failed.name,
          reason: '重启后失败记录不得消失');

      // 2) 恢复扫描命中 failed 行（一键重试的引擎句柄）
      final recovered = await repo.recoverOnStartup(onRequeue: (_) {});
      expect(recovered.map((r) => r.id), contains(rowId));

      // 3) 登记引擎 → 重试 → 206 续传完成
      Future<ResponseBody> serve(RequestOptions options) async {
        final raw = options.headers['Range'];
        final range = raw is String ? raw : null;
        if (range != null) {
          final from =
              int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          return ResponseBody(
            Stream<Uint8List>.fromIterable([body.sublist(from)]),
            206,
            headers: <String, List<String>>{
              'content-range': [
                'bytes $from-${body.length - 1}/${body.length}'
              ],
            },
          );
        }
        return ResponseBody(
          Stream<Uint8List>.fromIterable([body]),
          200,
          headers: <String, List<String>>{
            'content-length': ['${body.length}'],
          },
        );
      }

      final engine = DownloadEngine(
        dio: Dio()..httpClientAdapter = _StubAdapter(serve),
        downloadDir: tmpDir,
        store: RepoDownloadStore(repo),
      );
      final commands = EngineDownloadCommands(engine, repo);
      await restoreDownloadRecords(commands, recovered);
      await commands.retry(rowId);

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      dt.DownloadStatus? last;
      while (DateTime.now().isBefore(deadline)) {
        last = engine
            .task(EngineDownloadCommands.engineIdOf(rowId))
            ?.status;
        if (last == dt.DownloadStatus.completed) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(last, dt.DownloadStatus.completed, reason: '重启后重试可完成');
      expect(
          File(engine.task(EngineDownloadCommands.engineIdOf(rowId))!
              .filePath!)
              .readAsBytesSync(),
          body);

      await engine.dispose();
      await db.close();
    }
  });
}
