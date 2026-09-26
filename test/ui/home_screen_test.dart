// 首页 widget 测试（DESIGN §11.2）：
// 输入框清空 / 粘贴按钮 / 解析触发 / 剪贴板横幅出现与去重 / 骨架卡片+计时 /
// 七类错误视图切换中的 E01/E02 路径 / 成功弹 Sheet 与入队 toast /
// E02 指数退避自动重试（PRD §5，零抖动注入断言次数与间隔）/
// E07 端点漂移 → 配置仓库刷新 → 重建解析器重试一次（§6.7）/
// 「开始下载」连点防抖与业务键重复 toast / 首选清晰度 720p 偏好初始高亮。
// 全部 ProviderScope override，不触真网络与真插件通道。

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipvault/clipboard/clipboard_watcher.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/core/backoff.dart';
import 'package:clipvault/core/error.dart';
import 'package:clipvault/parse/endpoint_config.dart';
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/settings/settings_controller.dart';
import 'package:clipvault/sharing/share_receiver.dart';
import 'package:clipvault/ui/common/parse_skeleton.dart';
import 'package:clipvault/ui/common/preview_card.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';
import 'package:clipvault/ui/home/home_screen.dart';

const String _kUrl = 'https://x.com/someone/status/1790637656616943991?s=20';
const String _kTweetId = '1790637656616943991';

VideoVariant _variant(int bitrate, int w, int h) => VideoVariant(
      contentType: VariantContentType.mp4,
      bitrate: bitrate,
      url: 'https://video.twimg.com/ext_tw_video/vid/avc1/${w}x$h/x.mp4',
      width: w,
      height: h,
      // 与生产模型一致（models.dart：bitrate × durationMillis ~/ 8000）：
      // 90s × 2176000bps / 8 ≈ 24.5 MB（DESIGN §4.2 示例量级）
      estimatedBytes: bitrate * 90000 ~/ 8000,
    );

TweetMeta _meta() => TweetMeta(
      tweetId: _kTweetId,
      userName: '测试作者',
      screenName: 'tester',
      avatarUrl: '',
      text: '这是一条测试推文正文',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      thumbnailUrl: '',
      durationMillis: 90000,
      possiblySensitive: false,
      videoCount: 1,
      variants: [_variant(2176000, 1280, 720), _variant(832000, 640, 360)],
    );

/// 三档变体（1080p/720p/360p）：720p 偏好测试用（偏好档非最高档）
TweetMeta _metaThreeVariants() => TweetMeta(
      tweetId: _kTweetId,
      userName: '测试作者',
      screenName: 'tester',
      avatarUrl: '',
      text: '多档位测试推文',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      thumbnailUrl: '',
      durationMillis: 90000,
      possiblySensitive: false,
      videoCount: 1,
      variants: [
        _variant(3200000, 1920, 1080),
        _variant(2176000, 1280, 720),
        _variant(832000, 640, 360),
      ],
    );

class FakeTweetParser implements TweetParser {
  FakeTweetParser(this._handler);

  final Future<ResolveResult> Function(String tweetId) _handler;
  final List<String> requestedIds = [];

  @override
  Future<ResolveResult> resolve(String tweetId, {int videoIndex = 0}) {
    requestedIds.add(tweetId);
    return _handler(tweetId);
  }
}

class FakeClipboardReader implements ClipboardReader {
  final List<String?> _queue;

  FakeClipboardReader(Iterable<String?> reads) : _queue = List<String?>.of(reads);

  @override
  Future<String?> readText() async =>
      _queue.isNotEmpty ? _queue.removeAt(0) : null;
}

/// 可编程入队结果：默认成功，duplicate 场景改 [enqueueResult]
class FakeDownloadCommands implements DownloadCommands {
  FakeDownloadCommands({this.enqueueResult = DownloadEnqueueResult.enqueued});

  final List<String> log = <String>[];
  final DownloadEnqueueResult enqueueResult;

  @override
  Future<DownloadEnqueueResult> enqueue({
    required String tweetId,
    required VideoVariant variant,
    required String tweetJson,
  }) async {
    log.add('enqueue:$tweetId:${variant.bitrate}');
    return enqueueResult;
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

/// 端点配置仓库假实现：只控制 onEndpointDrift 返回值（§6.7 漂移刷新链路）
class FakeEndpointConfigRepository extends EndpointConfigRepository {
  FakeEndpointConfigRepository({
    required super.prefs,
    required this.driftRefreshed,
  }) : super(dio: Dio(), assetLoader: (_) async => null);

  final bool driftRefreshed;
  int driftCalls = 0;

  @override
  Future<bool> onEndpointDrift() async {
    driftCalls++;
    return driftRefreshed;
  }
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required FakeTweetParser parser,
  required FakeClipboardReader reader,
  required FakeDownloadCommands commands,
  List<Object> extraOverrides = const [],
}) async {
  // 手机比例视口：保证清晰度 Sheet（含预览卡）在测试画面内完整可见
  tester.view.physicalSize = const Size(412, 916);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // tweetParserProvider 为 FutureProvider（端点配置仓库接线），
        // 测试以 overrideWith 同步注入假实现
        tweetParserProvider.overrideWith((ref) => parser),
        // 零抖动退避：800/1600/320ms 精确断言重试间隔（PRD §5）
        parseRetryBackoffProvider.overrideWithValue(
          ExponentialBackoff(jitterFactory: (_) => Duration.zero),
        ),
        clipboardReaderProvider.overrideWithValue(reader),
        shareReceiverProvider.overrideWithValue(NoopShareReceiver()),
        downloadCommandsProvider.overrideWithValue(commands),
        downloadsWatchProvider.overrideWith((ref) => const Stream.empty()),
        ...extraOverrides.cast(),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
}

/// 触发一次 resume 生命周期（经 inactive 中转以满足生命周期状态机合法性）
///
/// 注：剪贴板读取是异步链（readText → 提取 → state 置位都落在微任务里），
/// 无帧待渲染时 pump() 只冲刷微任务不构建帧，故 resumed 后需补一帧
/// 让横幅的重建真正落地（生产环境对应下一个 vsync，语义一致）。
Future<void> _resumeApp(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  await tester.pump();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump(); // 冲刷微任务：readText 完成、watcher state 置位
  await tester.pump(); // 构建携带新 state 的帧
}

void main() {
  testWidgets('非法输入 → E01 视图，零网络请求', (tester) async {
    final parser = FakeTweetParser((_) async => throw StateError('不应触网'));
    final commands = FakeDownloadCommands();
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([null]),
      commands: commands,
    );

    await tester.enterText(find.byType(TextField), 'not-a-valid-url');
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();

    expect(find.text(AppStrings.errUrlInvalid), findsOneWidget);
    expect(parser.requestedIds, isEmpty);
  });

  testWidgets('解析中显示骨架卡片与耗时计时', (tester) async {
    final parser = FakeTweetParser((_) => Completer<ResolveResult>().future);
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([null]),
      commands: FakeDownloadCommands(),
    );

    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();

    expect(find.byType(ParseSkeleton), findsOneWidget);
    expect(find.textContaining(AppStrings.parsingInProgress), findsOneWidget);
    // 100ms tick 计数：300ms 后应显示 0.3 s
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('0.3 s'), findsOneWidget);
  });

  testWidgets('解析成功 → 弹出清晰度 Sheet，开始下载触发入队与 toast', (tester) async {
    final parser = FakeTweetParser((_) async => ResolveResult(tweet: _meta(), parserVersion: 'syndication-v1'));
    final commands = FakeDownloadCommands();
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([null]),
      commands: commands,
    );

    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(AppStrings.qualitySheetTitle), findsOneWidget);
    // 默认高亮最高码率档（720p 为该推文最高档）
    expect(find.text('720p (HD)'), findsOneWidget);

    await tester.tap(find.text(AppStrings.qualityStartDownload));
    await tester.pump();
    expect(commands.log, contains('enqueue:$_kTweetId:2176000'));
    expect(find.text(AppStrings.toastEnqueued), findsOneWidget);
  });

  testWidgets('连点「开始下载」只入队一次且 Sheet 关闭（review C2）', (tester) async {
    final parser = FakeTweetParser((_) async => ResolveResult(tweet: _meta(), parserVersion: 'syndication-v1'));
    final commands = FakeDownloadCommands();
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([null]),
      commands: commands,
    );

    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(AppStrings.qualitySheetTitle), findsOneWidget);

    // 同帧快速连点两次：按钮触发即禁用 + Sheet 关闭，第二次落空
    final button = find.text(AppStrings.qualityStartDownload);
    await tester.tap(button);
    await tester.tap(button, warnIfMissed: false);
    await tester.pump();

    expect(
      commands.log.where((entry) => entry.startsWith('enqueue:')).length,
      1,
    );
    expect(find.text(AppStrings.toastEnqueued), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.qualitySheetTitle), findsNothing);
  });

  testWidgets('业务键重复入队 → taskAlreadyQueued toast（不弹成功语）', (tester) async {
    final parser = FakeTweetParser((_) async => ResolveResult(tweet: _meta(), parserVersion: 'syndication-v1'));
    final commands = FakeDownloadCommands(
      enqueueResult: DownloadEnqueueResult.duplicate,
    );
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([null]),
      commands: commands,
    );

    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text(AppStrings.qualityStartDownload));
    await tester.pump();

    expect(find.text(AppStrings.taskAlreadyQueued), findsOneWidget);
    expect(find.text(AppStrings.toastEnqueued), findsNothing);
  });

  testWidgets('首选清晰度 720p 偏好：Sheet 初始高亮 720p 档（§3.2 省流）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kPrefSettingsQualityMode: kQualityMode720p,
    });
    final parser = FakeTweetParser(
      (_) async => ResolveResult(tweet: _metaThreeVariants(), parserVersion: 'syndication-v1'),
    );
    final commands = FakeDownloadCommands();
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([null]),
      commands: commands,
    );
    // 设置异步加载完成后再触发解析（偏好取值已就绪）
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(AppStrings.qualitySheetTitle), findsOneWidget);

    // 默认（highest）应高亮 1080p；偏好 720p 后高亮 720p 行
    final row720 = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '720p (HD)'),
    );
    expect(row720.selected, isTrue);
    final row1080 = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '1080p (Full HD)'),
    );
    expect(row1080.selected, isFalse);

    // 直接点「开始下载」入队的是 720p 档（而非最高 1080p 大体积档）
    await tester.tap(find.text(AppStrings.qualityStartDownload));
    await tester.pump();
    expect(commands.log, contains('enqueue:$_kTweetId:2176000'));
  });

  // 原测试「网络类错误显示重试按钮，重试后成功」断言单次失败即透出错误——
  // C7 修复后 E02 按索引退避自动重试 3 次才透出（PRD §5），原断言编码的
  // 即修复前的缺陷行为，改为断言重试次数/间隔与最终透出。
  testWidgets('E02 指数退避自动重试 3 次（800/1600/320ms），耗尽才透出错误', (tester) async {
    var attempts = 0;
    var failing = true;
    final parser = FakeTweetParser((_) async {
      attempts++;
      if (failing) throw NetworkTimeout();
      return ResolveResult(tweet: _meta(), parserVersion: 'syndication-v1');
    });
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([null]),
      commands: FakeDownloadCommands(),
    );

    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();
    // 第 1 次失败 → 进入退避；骨架持续、无错误视图
    expect(attempts, 1);
    expect(find.byType(ParseSkeleton), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 800));
    expect(attempts, 2); // 退避 800ms 后第 2 次尝试
    expect(find.byType(ParseSkeleton), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1600));
    expect(attempts, 3); // 退避 1.6s 后第 3 次尝试

    await tester.pump(const Duration(milliseconds: 3200));
    expect(attempts, 4); // 退避 3.2s 后第 4 次（1+3）尝试，耗尽
    expect(find.text(AppStrings.errNetworkTimeout), findsOneWidget);

    // 手动一键重试：恢复后成功 → 弹 Sheet
    failing = false;
    await tester.tap(find.text(AppStrings.actionRetry));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(attempts, 5);
    expect(find.text(AppStrings.qualitySheetTitle), findsOneWidget);
  });

  testWidgets('非网络类错误（E04）不自动重试，单次即透出', (tester) async {
    var attempts = 0;
    final parser = FakeTweetParser((_) async {
      attempts++;
      throw TweetNotFound();
    });
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([null]),
      commands: FakeDownloadCommands(),
    );

    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump(const Duration(milliseconds: 700));

    expect(attempts, 1);
    expect(find.text(AppStrings.errTweetNotFound), findsOneWidget);
  });

  testWidgets('E07 漂移 → 配置刷新成功 → 重建解析器重试一次后成功（§6.7）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final repo = FakeEndpointConfigRepository(prefs: prefs, driftRefreshed: true);
    var attempts = 0;
    final parser = FakeTweetParser((_) async {
      attempts++;
      if (attempts == 1) throw const EndpointDrift();
      return ResolveResult(tweet: _meta(), parserVersion: 'syndication-v1');
    });
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([null]),
      commands: FakeDownloadCommands(),
      extraOverrides: [
        endpointConfigRepositoryProvider.overrideWith((ref) async => repo),
      ],
    );

    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 漂移触发 onEndpointDrift → 刷新到新配置 → 重建解析器重试成功
    expect(repo.driftCalls, 1);
    expect(attempts, 2);
    expect(find.text(AppStrings.qualitySheetTitle), findsOneWidget);
  });

  testWidgets('E07 漂移但无新配置：透出错误，不无限重试', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final repo = FakeEndpointConfigRepository(prefs: prefs, driftRefreshed: false);
    var attempts = 0;
    final parser = FakeTweetParser((_) async {
      attempts++;
      throw const EndpointDrift();
    });
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([null]),
      commands: FakeDownloadCommands(),
      extraOverrides: [
        endpointConfigRepositoryProvider.overrideWith((ref) async => repo),
      ],
    );

    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(repo.driftCalls, 1);
    expect(attempts, 1); // 无新配置不重建重试
    expect(find.text(AppStrings.errEndpointDrift), findsOneWidget);
  });

  testWidgets('剪贴板 resume 横幅出现、点击解析、同链接去重', (tester) async {
    final parser = FakeTweetParser((_) async => ResolveResult(tweet: _meta(), parserVersion: 'syndication-v1'));
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([null, _kUrl, _kUrl, _kUrl]),
      commands: FakeDownloadCommands(),
    );

    // 首次 resume：无剪贴板内容 → 无横幅
    await _resumeApp(tester);
    expect(find.text(AppStrings.clipboardBanner), findsNothing);

    // 第二次 resume：命中链接 → 横幅
    await _resumeApp(tester);
    expect(find.text(AppStrings.clipboardBanner), findsOneWidget);

    // 点击横幅 → 消费并解析
    await tester.tap(find.text(AppStrings.clipboardBanner));
    await tester.pump();
    expect(find.text(AppStrings.clipboardBanner), findsNothing);
    expect(parser.requestedIds, contains(_kTweetId));

    // 关闭 Sheet 回到首页
    await tester.pump(const Duration(milliseconds: 300));

    // 第三次 resume（inactive 瞬时遮挡，未离开 App）：同一链接 → 去重不出横幅
    await _resumeApp(tester);
    expect(find.text(AppStrings.clipboardBanner), findsNothing);

    // 真正离开 App（inactive→hidden→paused）再回来：用户可能重新复制了
    // 同一链接 → 横幅再次出现（P2-1：去重键在离开前台时重置）。
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    await tester.pump();
    expect(find.text(AppStrings.clipboardBanner), findsOneWidget);
  });

  testWidgets('解析中可取消；取消后旧请求完成不落位结果（P0-1 竞态守卫）', (tester) async {
    final completer = Completer<ResolveResult>();
    final parser = FakeTweetParser((_) => completer.future);
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader(const []),
      commands: FakeDownloadCommands(),
    );

    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();

    // 骨架卡出现且带「取消解析」出口
    expect(find.byType(ParseSkeleton), findsOneWidget);
    expect(find.text(AppStrings.actionCancelParse), findsOneWidget);

    // 取消 → 回 idle（骨架消失），不再被退避重试锁死
    await tester.tap(find.text(AppStrings.actionCancelParse));
    await tester.pump();
    expect(find.byType(ParseSkeleton), findsNothing);

    // 旧请求此刻完成：代际已过期，结果被丢弃（不置 resolved、不弹 Sheet）
    completer.complete(
        ResolveResult(tweet: _meta(), parserVersion: 'syndication-v1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(AppStrings.qualitySheetTitle), findsNothing);
    expect(find.byType(PreviewCard), findsNothing);
  });

  testWidgets('同推文重复解析：最近解析去重置顶（P2-3）', (tester) async {
    final parser =
        FakeTweetParser((_) async => ResolveResult(tweet: _meta(), parserVersion: 'syndication-v1'));
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader(const []),
      commands: FakeDownloadCommands(),
    );

    Future<void> parseOnce() async {
      await tester.enterText(find.byType(TextField), _kUrl);
      await tester.tap(find.text(AppStrings.homePasteAndParse));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 关闭弹出的 Sheet（无本地化代理时按 icon 定位关闭按钮）
      final close = find.byIcon(Icons.close);
      if (close.evaluate().isNotEmpty) {
        await tester.tap(close.first);
        await tester.pumpAndSettle();
      }
    }

    await parseOnce();
    await parseOnce();

    // 同推文只保留一条（去重置顶），作者文本不重复堆叠
    expect(find.text('测试作者'), findsOneWidget);
  });

  testWidgets('合并 CTA：输入为空时读剪贴板解析并回填；空输入+空剪贴板给反馈；清空可用（主题 G）', (tester) async {
    final parser = FakeTweetParser((_) async => ResolveResult(tweet: _meta(), parserVersion: 'syndication-v1'));
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([_kUrl, null, null]),
      commands: FakeDownloadCommands(),
    );

    // 输入为空 → CTA 读剪贴板、回填并解析
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, _kUrl);
    expect(parser.requestedIds, contains(_kTweetId));
    // 关闭弹出的 Sheet
    final close = find.byIcon(Icons.close);
    if (close.evaluate().isNotEmpty) {
      await tester.tap(close.first);
      await tester.pumpAndSettle();
    }
    // 清空输入
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();
    final cleared = tester.widget<TextField>(find.byType(TextField));
    expect(cleared.controller?.text, isEmpty);

    // 空输入 + 空剪贴板 → 可感知反馈（不再静默无反应）
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();
    expect(find.text(AppStrings.homeEmptyInput), findsOneWidget);
    expect(parser.requestedIds.where((id) => id == _kTweetId).length, 1);
  });

  testWidgets('成功解析后最近解析区显示作者与时长', (tester) async {
    final parser = FakeTweetParser((_) async => ResolveResult(tweet: _meta(), parserVersion: 'syndication-v1'));
    await _pumpHome(
      tester,
      parser: parser,
      reader: FakeClipboardReader([null]),
      commands: FakeDownloadCommands(),
    );

    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 关闭 Sheet 露出最近解析
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text(AppStrings.recentParsed), findsOneWidget);
    expect(find.textContaining('@tester'), findsWidgets);
  });
}
