// 下载 Tab widget 测试（DESIGN §11.2）：
// 任务 tile 进度/速率/ETA、暂停取消、失败区重试、429 冷却横幅、
// 历史条目字段与删除、重存入口（albumSavedAt 空）。
// downloadsWatchProvider / downloadCommandsProvider / historyCommandsProvider 全 override。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/data/tables.dart' show DownloadStatus;
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/ui/downloads/downloads_screen.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';
import 'package:clipvault/ui/history/history_screen.dart';

class FakeDownloadCommands implements DownloadCommands {
  final List<String> log = <String>[];

  @override
  Future<DownloadEnqueueResult> enqueue({
    required String tweetId,
    required VideoVariant variant,
    required String tweetJson,
  }) async {
    log.add('enqueue');
    return DownloadEnqueueResult.enqueued;
  }

  @override
  Future<void> pause(int id) async => log.add('pause:$id');

  @override
  Future<void> resume(int id) async => log.add('resume:$id');

  @override
  Future<void> cancel(int id) async => log.add('cancel:$id');

  @override
  Future<void> retry(int id) async => log.add('retry:$id');
}

class FakeHistoryCommands implements HistoryCommands {
  final List<String> log = <String>[];

  @override
  Future<void> delete(int id) async => log.add('delete:$id');

  @override
  Future<bool> resaveToGallery(int id, String filePath) async {
    log.add('resave:$id');
    return true;
  }

  @override
  Future<void> shareFile(String filePath) async => log.add('share:$filePath');
}

String _snapshotJson({String text = '测试视频推文', String thumb = ''}) =>
    '{"tweetId":"1790637656616943991","userName":"测试作者","screenName":"tester",'
    '"text":"$text","thumbnailUrl":"$thumb","durationMillis":90000}';

TaskItem _item({
  required int id,
  required DownloadStatus status,
  int? bytesTotal = 10 * 1024 * 1024,
  int bytesDone = 5 * 1024 * 1024,
  int speedBps = 1572864,
  int? etaSec = 83,
  String? errorCode,
  String? filePath,
  DateTime? albumSavedAt,
  String? tweetJson,
  DateTime? createdAt,
}) {
  return TaskItem(
    id: id,
    tweetId: '1790637656616943991',
    status: status,
    qualityLabel: '720p (HD)',
    bytesTotal: bytesTotal,
    bytesDone: bytesDone,
    speedBps: speedBps,
    etaSec: etaSec,
    errorCode: errorCode,
    filePath: filePath,
    albumSavedAt: albumSavedAt,
    tweetJson: tweetJson,
    createdAt: createdAt ?? DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required List<TaskItem> items,
  required FakeDownloadCommands commands,
  FakeHistoryCommands? historyCommands,
  Stream<DateTime?> cooling = const Stream.empty(),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        downloadsWatchProvider.overrideWith((ref) => Stream.value(items)),
        downloadCommandsProvider.overrideWithValue(commands),
        coolingProvider.overrideWith((ref) => cooling),
        // 详情实时流统一空覆盖：本文件不触真实 drift（详情页回落快照渲染；
        // 否则真实 LazyDatabase/path_provider 在测试环境留下挂起 Timer）
        historyDetailProvider.overrideWith((ref, id) => const Stream.empty()),
        if (historyCommands != null)
          historyCommandsProvider.overrideWithValue(historyCommands),
      ],
      child: const MaterialApp(home: DownloadsScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('空任务列表显示空态文案', (tester) async {
    await _pump(tester, items: const [], commands: FakeDownloadCommands());
    expect(find.text(AppStrings.dlEmpty), findsOneWidget);
  });

  testWidgets('进行中任务展示进度百分比/速率/已用时间与暂停取消', (tester) async {
    final commands = FakeDownloadCommands();
    await _pump(
      tester,
      items: [
        _item(
          id: 1,
          status: DownloadStatus.running,
          createdAt: DateTime.now().subtract(const Duration(seconds: 90)),
        ),
      ],
      commands: commands,
    );

    expect(find.text('50%'), findsOneWidget);
    expect(find.textContaining('1.50 MB/s'), findsOneWidget);
    // 已用时间与速率/ETA 同行（PRD 3.3；createdAt 差值 90s → 已用 1:30）
    expect(find.textContaining('${AppStrings.labelElapsed} 1:30'), findsOneWidget);
    expect(find.byTooltip(AppStrings.actionPause), findsOneWidget);
    expect(find.byTooltip(AppStrings.actionCancel), findsOneWidget);

    await tester.tap(find.byTooltip(AppStrings.actionPause));
    await tester.pump();
    expect(commands.log, contains('pause:1'));
  });

  testWidgets('等待队列与失败区重试（errorCode 双取值域话术）', (tester) async {
    final commands = FakeDownloadCommands();
    await _pump(
      tester,
      items: [
        _item(id: 2, status: DownloadStatus.queued, bytesDone: 0, speedBps: 0, etaSec: null),
        _item(
          id: 3,
          status: DownloadStatus.failed,
          errorCode: 'E02',
          bytesDone: 0,
          speedBps: 0,
          etaSec: null,
        ),
        _item(
          id: 5,
          status: DownloadStatus.failed,
          errorCode: 'urlExpired',
          bytesDone: 0,
          speedBps: 0,
          etaSec: null,
        ),
      ],
      commands: commands,
    );

    expect(find.text(AppStrings.dlSectionQueued), findsOneWidget);
    expect(find.text(AppStrings.dlSectionFailed), findsOneWidget);
    // 解析域码 E02 与引擎 failureKind 名 urlExpired 各自映射专属话术
    expect(find.text(AppStrings.errNetworkTimeout), findsOneWidget);
    expect(find.text(AppStrings.errDownloadUrlExpired), findsOneWidget);

    await tester.tap(find.byTooltip(AppStrings.actionRetry).first);
    await tester.pump();
    expect(commands.log, contains('retry:3'));
  });

  testWidgets('429 冷却通知横幅（引擎 notices 触发）', (tester) async {
    final commands = FakeDownloadCommands();
    await _pump(
      tester,
      items: [_item(id: 4, status: DownloadStatus.paused)],
      commands: commands,
      cooling: Stream<DateTime?>.value(DateTime.fromMillisecondsSinceEpoch(9900000000000)),
    );
    // Stream.value 的事件经微任务投递 → AsyncLoading→Data 需再一帧重建
    await tester.pump();

    expect(find.text(AppStrings.cooldownNotice), findsOneWidget);
  });

  testWidgets('历史条目展示字段，进入详情可重存（albumSavedAt 空）与删除', (tester) async {
    final commands = FakeDownloadCommands();
    final historyCommands = FakeHistoryCommands();
    final historyItem = _item(
      id: 9,
      status: DownloadStatus.completed,
      bytesDone: 10 * 1024 * 1024,
      speedBps: 0,
      etaSec: null,
      filePath: '/data/downloads/1790637656616943991_2176000.mp4',
      albumSavedAt: null,
      tweetJson: _snapshotJson(),
    );
    await _pump(
      tester,
      items: [historyItem],
      commands: commands,
      historyCommands: historyCommands,
    );

    // 历史行字段：标题 / 清晰度 / 未入相册标识
    expect(find.text('测试视频推文'), findsOneWidget);
    expect(find.textContaining('720p (HD)'), findsWidgets);
    expect(find.textContaining(AppStrings.albumNotSaved), findsOneWidget);

    // 进入详情 → 重存入口可见并回调
    await tester.tap(find.byType(TaskTile));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryScreen), findsOneWidget);
    expect(find.text(AppStrings.actionResave), findsOneWidget);

    await tester.tap(find.text(AppStrings.actionResave));
    await tester.pump();
    expect(historyCommands.log, contains('resave:9'));

    // 删除：详情页按钮（OutlinedButton）→ 确认弹窗 → 弹窗内 FilledButton 确认
    await tester.tap(find.widgetWithText(OutlinedButton, AppStrings.actionDelete));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.deleteConfirm), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, AppStrings.actionDelete));
    await tester.pumpAndSettle();
    expect(historyCommands.log, contains('delete:9'));
  });
}
