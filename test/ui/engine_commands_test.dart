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
import 'package:drift/drift.dart' show DatabaseConnection;
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
}
