// EngineDownloadCommands 入队编排测试（review C4 仅 Wi-Fi / C2 业务键去重）：
// - 仅 Wi-Fi 偏好开启且非 Wi-Fi：行保持 queued 暂不交引擎（waitingWifi），
//   Wi-Fi 恢复（连接流）补交；挂起期间取消直接落库终态；
// - 同 (tweetId, bitrate) 引擎已有未终结任务：拒绝且不建行（duplicate）；
// - 正常路径：建行 + 交引擎（enqueued）。
// 引擎经 stub httpClientAdapter 注入（404 立即失败 / 永不完成），不触网络。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipvault/data/database.dart';
import 'package:clipvault/data/history_repository.dart';
import 'package:clipvault/data/tables.dart' show DownloadStatus;
import 'package:clipvault/download/download_engine.dart';
import 'package:clipvault/download/download_task.dart' as dt;
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';

AppDatabase createDb() => AppDatabase(
      DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
    );

/// 可脚本化的 dio 适配器：按 [fetch] 回调返回响应体（离线）
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.fetchHandler);

  final Future<ResponseBody> Function(RequestOptions options) fetchHandler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      fetchHandler(options);

  @override
  void close({bool force = false}) {}
}

/// 立即 404：任务入队后即刻 failed(permanent)，无重试定时器
Future<ResponseBody> _notFound(RequestOptions options) async {
  return ResponseBody(Stream<Uint8List>.fromIterable(const <Uint8List>[]), 404);
}

/// 永不完成：任务停在 running（构造引擎内「未终结」活动任务用）
Future<ResponseBody> _hang(RequestOptions options) =>
    Completer<ResponseBody>().future;

class _FakeConnectivity implements ConnectivityChecker {
  _FakeConnectivity(this.onWifi);

  bool onWifi;
  final StreamController<bool> events = StreamController<bool>.broadcast();

  @override
  Future<bool> get isOnWifi async => onWifi;

  @override
  Stream<bool> get onWifiChanged => events.stream;

  Future<void> dispose() => events.close();
}

VideoVariant _variant(int bitrate) => VideoVariant(
      contentType: VariantContentType.mp4,
      bitrate: bitrate,
      url: 'https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/1280x720/x.mp4',
      width: 1280,
      height: 720,
      estimatedBytes: bitrate * 90000 ~/ 8000,
    );

dt.DownloadTask _engineTask(String id, String tweetId, int bitrate) =>
    dt.DownloadTask.create(
      id: id,
      tweetId: tweetId,
      variantUrl: 'https://video.twimg.com/x.mp4',
      bitrate: bitrate,
      qualityLabel: '720p (HD)',
    );

/// 永不报告 Wi-Fi 的空连接检查（并发接线测试隔离插件通道用）
class _NeverConnectivity implements ConnectivityChecker {
  const _NeverConnectivity();

  @override
  Future<bool> get isOnWifi async => false;

  @override
  Stream<bool> get onWifiChanged => const Stream<bool>.empty();
}

Future<void> _pumpEventQueue() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late AppDatabase db;
  late HistoryRepository repo;
  late Directory tmpDir;

  setUp(() async {
    db = createDb();
    repo = HistoryRepository(db);
    tmpDir = await Directory.systemTemp.createTemp('xdown_commands_test');
  });

  tearDown(() async {
    await db.close();
    await tmpDir.delete(recursive: true);
  });

  DownloadEngine newEngine(
    Future<ResponseBody> Function(RequestOptions options) fetchHandler,
  ) {
    final dio = Dio()..httpClientAdapter = _StubAdapter(fetchHandler);
    return DownloadEngine(dio: dio, downloadDir: tmpDir);
  }

  test('正常入队：建行 + 交引擎（enqueued）', () async {
    final engine = newEngine(_notFound);
    final commands = EngineDownloadCommands(engine, repo);
    addTearDown(commands.dispose);
    addTearDown(() => engine.dispose());

    final result = await commands.enqueue(
      tweetId: '1790637656616943991',
      variant: _variant(2176000),
      tweetJson: '{"tweetId":"1790637656616943991"}',
    );

    expect(result, DownloadEnqueueResult.enqueued);
    final rows = await repo.getAll();
    expect(rows, hasLength(1));
    expect(rows.first.status, DownloadStatus.queued.name);
    expect(
      engine.task(EngineDownloadCommands.engineIdOf(rows.first.id)),
      isNotNull,
    );
  });

  test('仅 Wi-Fi 偏好 + 非 Wi-Fi：waitingWifi 挂起，Wi-Fi 恢复后补交引擎', () async {
    final engine = newEngine(_notFound);
    final connectivity = _FakeConnectivity(false);
    final commands = EngineDownloadCommands(
      engine,
      repo,
      wifiOnlyEnabled: () => true,
      connectivity: connectivity,
    );
    addTearDown(commands.dispose);
    addTearDown(connectivity.dispose);
    addTearDown(() => engine.dispose());

    final result = await commands.enqueue(
      tweetId: '1790637656616943991',
      variant: _variant(2176000),
      tweetJson: '{"tweetId":"1790637656616943991"}',
    );

    // 行保持 queued（等待队列可见），但引擎未接管（不产生网络请求）
    expect(result, DownloadEnqueueResult.waitingWifi);
    final rows = await repo.getAll();
    expect(rows.single.status, DownloadStatus.queued.name);
    expect(
      engine.task(EngineDownloadCommands.engineIdOf(rows.single.id)),
      isNull,
    );

    // Wi-Fi 恢复 → 连接流事件 → 补交引擎
    connectivity.onWifi = true;
    connectivity.events.add(true);
    await _pumpEventQueue();

    expect(
      engine.task(EngineDownloadCommands.engineIdOf(rows.single.id)),
      isNotNull,
    );
  });

  test('挂起期间取消：直接落库 canceled，Wi-Fi 恢复后也不再补交', () async {
    final engine = newEngine(_notFound);
    final connectivity = _FakeConnectivity(false);
    final commands = EngineDownloadCommands(
      engine,
      repo,
      wifiOnlyEnabled: () => true,
      connectivity: connectivity,
    );
    addTearDown(commands.dispose);
    addTearDown(connectivity.dispose);
    addTearDown(() => engine.dispose());

    await commands.enqueue(
      tweetId: '1790637656616943991',
      variant: _variant(2176000),
      tweetJson: '{"tweetId":"1790637656616943991"}',
    );
    final rowId = (await repo.getAll()).single.id;

    await commands.cancel(rowId);
    expect((await repo.getById(rowId))!.status, DownloadStatus.canceled.name);

    connectivity.onWifi = true;
    connectivity.events.add(true);
    await _pumpEventQueue();
    expect(engine.task(EngineDownloadCommands.engineIdOf(rowId)), isNull);
  });

  test('同 (tweetId, bitrate) 引擎已有活动任务：duplicate 且不建新行', () async {
    final engine = newEngine(_hang);
    final commands = EngineDownloadCommands(engine, repo);
    addTearDown(commands.dispose);
    addTearDown(() => engine.dispose());

    // 引擎内先有一个同业务键的 running 任务（不经仓库）
    engine.enqueue(
      _engineTask(EngineDownloadCommands.engineIdOf(999), '1790637656616943991', 2176000),
    );
    await _pumpEventQueue();

    final result = await commands.enqueue(
      tweetId: '1790637656616943991',
      variant: _variant(2176000),
      tweetJson: '{"tweetId":"1790637656616943991"}',
    );

    expect(result, DownloadEnqueueResult.duplicate);
    expect(await repo.getAll(), isEmpty); // 未建行（无孤儿行）
  });

  test('并发数偏好接线：设置加载即应用 engine.concurrency（review C4）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'settings.concurrency': 1,
    });
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      connectivityCheckerProvider.overrideWith(
        (ref) => const _NeverConnectivity(),
      ),
    ]);
    addTearDown(container.dispose);

    // 触发设置与引擎 provider 初始化（异步偏好经 listen 应用到引擎）
    final engine = container.read(downloadEngineProvider);
    await _pumpEventQueue();

    expect(engine.concurrency, 1); // prefs 恢复值覆盖引擎默认 2
  });

  test('启动恢复分流（P0-2）：偏好开启且非 Wi-Fi → 挂起不入引擎；Wi-Fi 恢复补交', () async {
    final engine = newEngine(_notFound);
    final connectivity = _FakeConnectivity(false);
    final commands = EngineDownloadCommands(
      engine,
      repo,
      wifiOnlyEnabled: () => true,
      connectivity: connectivity,
    );
    addTearDown(commands.dispose);
    addTearDown(() => connectivity.dispose());
    addTearDown(() => engine.dispose());

    // 预置一条未完成行（模拟上次会话中断遗留）
    final row = await repo.createTask(DownloadRecordsCompanion.insert(
      tweetId: '1790637656616943991',
      variantUrl: 'https://video.twimg.com/x.mp4',
      contentType: 'mp4',
      bitrate: 2176000,
      qualityLabel: '720p (HD)',
      status: DownloadStatus.queued.name,
      tweetJson: '{"tweetId":"1790637656616943991"}',
    ));

    // 蜂窝网络下启动恢复：不入引擎（挂起等待 Wi-Fi，不走流量）
    await commands.restoreRecords([row]);
    expect(
      engine.task(EngineDownloadCommands.engineIdOf(row.id)),
      isNull,
    );

    // Wi-Fi 恢复 → 补交引擎（404 立即失败即证明已被调度）
    connectivity.onWifi = true;
    connectivity.events.add(true);
    for (var i = 0; i < 10; i++) {
      await _pumpEventQueue();
    }
    final task = engine.task(EngineDownloadCommands.engineIdOf(row.id));
    expect(task?.isSettled, isTrue);
    expect(task?.failureKind, dt.DownloadFailureKind.permanent);
  });

  test('启动恢复分流（P0-2）：Wi-Fi 可用 → 直接交引擎续传', () async {
    final engine = newEngine(_notFound);
    final connectivity = _FakeConnectivity(true);
    final commands = EngineDownloadCommands(
      engine,
      repo,
      wifiOnlyEnabled: () => true,
      connectivity: connectivity,
    );
    addTearDown(commands.dispose);
    addTearDown(() => connectivity.dispose());
    addTearDown(() => engine.dispose());

    final row = await repo.createTask(DownloadRecordsCompanion.insert(
      tweetId: '1790637656616943992',
      variantUrl: 'https://video.twimg.com/x.mp4',
      contentType: 'mp4',
      bitrate: 832000,
      qualityLabel: '480p (SD)',
      status: DownloadStatus.queued.name,
      tweetJson: '{"tweetId":"1790637656616943992"}',
    ));

    await commands.restoreRecords([row]);
    for (var i = 0; i < 10; i++) {
      await _pumpEventQueue();
    }
    // 404 立即失败即证明已交引擎调度（而非被挂起）
    final task = engine.task(EngineDownloadCommands.engineIdOf(row.id));
    expect(task?.isSettled, isTrue);
  });

  test('删除记录（用户反馈 2026-09-30）：仅删行与断点残片，视频文件保留', () async {
    final engine = newEngine(_hang);
    final commands = EngineDownloadCommands(engine, repo);
    addTearDown(commands.dispose);
    addTearDown(() => engine.dispose());

    final row = await repo.createTask(DownloadRecordsCompanion.insert(
      tweetId: '1790637656616943993',
      variantUrl: 'https://video.twimg.com/x.mp4',
      contentType: 'mp4',
      bitrate: 2176000,
      qualityLabel: '720p (HD)',
      status: DownloadStatus.completed.name,
      tweetJson: '{"tweetId":"1790637656616943993"}',
    ));
    // 沙盒成品视频 + 断点残片（取消/失败场景遗留）
    final video = File('${tmpDir.path}/done.mp4')..writeAsStringSync('v');
    final part = File('${tmpDir.path}/done.mp4.part')..writeAsStringSync('p');
    await repo.apply(
      row.id,
      DownloadRecordsCompanion(
        filePath: Value(video.path),
        partPath: Value(part.path),
      ),
    );

    await commands.deleteRecord(row.id);

    expect(await repo.getById(row.id), isNull);
    expect(await video.exists(), isTrue, reason: '成品视频文件保留');
    expect(await part.exists(), isFalse, reason: '断点残片随行清理');

    // 幂等：重复删除（行已不存在）不抛异常
    await commands.deleteRecord(row.id);
  });

  test('删除记录：同键重下任务运行中引用 .part 时不清理残片（守卫回归）', () async {
    final engine = newEngine(_hang);
    final commands = EngineDownloadCommands(engine, repo);
    addTearDown(commands.dispose);
    addTearDown(() => engine.dispose());

    // 行1：已取消旧行，partPath 已落库（取消语义保留断点）
    final part = File('${tmpDir.path}/1790637656616943994_2176000.part')
      ..writeAsStringSync('p');
    final oldRow = await repo.createTask(DownloadRecordsCompanion.insert(
      tweetId: '1790637656616943994',
      variantUrl: 'https://video.twimg.com/x.mp4',
      contentType: 'mp4',
      bitrate: 2176000,
      qualityLabel: '720p (HD)',
      status: DownloadStatus.canceled.name,
      tweetJson: '{"tweetId":"1790637656616943994"}',
    ));
    await repo.apply(oldRow.id,
        DownloadRecordsCompanion(partPath: Value(part.path)));

    // 行2：同 (tweetId, bitrate) 重下，paused 未终结且携带同一 .part
    // （.part 路径由业务键确定性派生，与行 id 无关）
    final activeRow = await repo.createTask(DownloadRecordsCompanion.insert(
      tweetId: '1790637656616943994',
      variantUrl: 'https://video.twimg.com/x.mp4',
      contentType: 'mp4',
      bitrate: 2176000,
      qualityLabel: '720p (HD)',
      status: DownloadStatus.paused.name,
      tweetJson: '{"tweetId":"1790637656616943994"}',
    ));
    await repo.apply(activeRow.id,
        DownloadRecordsCompanion(partPath: Value(part.path)));
    await commands.restoreRecords([(await repo.getById(activeRow.id))!]);

    // 删除旧取消行：行删除，但活动任务引用中的 .part 不被 unlink
    await commands.deleteRecord(oldRow.id);

    expect(await repo.getById(oldRow.id), isNull);
    expect(await repo.getById(activeRow.id), isNotNull);
    expect(await part.exists(), isTrue,
        reason: '活动任务引用中的断点残片不清理');
  });

  test('重启后重试失败任务（回归 2026-10-04）：恢复扫描含 failed 行，'
      '重试从 .part 断点续传而非无操作/归零', () async {
    // 服务器语义：带 Range → 206 续传；无 Range → 200 全量
    final body = Uint8List.fromList(
        List<int>.generate(8 * 1024, (i) => i & 0xFF));
    final seenRanges = <String?>[];
    Future<ResponseBody> serve(RequestOptions options) async {
      final raw = options.headers['Range'];
      final range = raw is String ? raw : null;
      seenRanges.add(range);
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

    // 按生产接线构造：dio 走 stub CDN，store 接 RepoDownloadStore
    //（引擎状态需回写 DB 行，与 downloadEngineProvider 装配一致）
    final engine = DownloadEngine(
      dio: Dio()..httpClientAdapter = _StubAdapter(serve),
      downloadDir: tmpDir,
      store: RepoDownloadStore(repo),
    );
    final commands = EngineDownloadCommands(engine, repo);
    addTearDown(commands.dispose);
    addTearDown(() => engine.dispose());

    // 上次会话遗留：failed 行 + .part 残片（4096 字节已送达）
    final part = File(
        '${tmpDir.path}${Platform.pathSeparator}1790637656616943995_2176000.part')
      ..writeAsBytesSync(body.sublist(0, 4096));
    var row = await repo.createTask(DownloadRecordsCompanion.insert(
      tweetId: '1790637656616943995',
      variantUrl: 'https://video.twimg.com/x.mp4',
      contentType: 'mp4',
      bitrate: 2176000,
      qualityLabel: '720p (HD)',
      status: DownloadStatus.failed.name,
      tweetJson: '{"tweetId":"1790637656616943995"}',
    ));
    await repo.apply(row.id, DownloadRecordsCompanion(
          partPath: Value(part.path),
          bytesDone: const Value(4096),
          bytesTotal: Value(body.length),
        ));

    // 本次启动：恢复扫描 → 分流（与 main._bootstrapRecovery 同路径）
    final recovered = await repo.recoverOnStartup(onRequeue: (_) {});
    await restoreDownloadRecords(commands, recovered);

    // 用户点「重试」
    await commands.retry(row.id);
    // 轮询至引擎完成且 DB 行落库完成（upsert 是 fire-and-forget 异步回写）
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final t = engine.task(EngineDownloadCommands.engineIdOf(row.id));
      final rowNow = await repo.getById(row.id);
      if (t?.status == dt.DownloadStatus.completed &&
          rowNow?.status == DownloadStatus.completed.name) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final t = engine.task(EngineDownloadCommands.engineIdOf(row.id));
    expect(t, isNotNull, reason: 'failed 行经恢复登记进引擎，重试才有句柄');
    expect(t?.status, dt.DownloadStatus.completed,
        reason: 'err=${t?.errorMessage} ranges=$seenRanges');
    expect(seenRanges, <String?>['bytes=4096-'], reason: '从断点续传而非归零');
    expect(File(t!.filePath!).readAsBytesSync(), body);
    row = (await repo.getById(row.id))!;
    expect(row.status, DownloadStatus.completed.name);
  });
}
