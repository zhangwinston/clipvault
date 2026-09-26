/// UI 视觉评审截图采集（golden 渲染）：把关键屏幕渲染成真实 PNG，
/// 供 UI 专家 workflow 对着实际界面评估易用性与美观。
///
/// 运行（本机）：flutter test --update-goldens test/ui/ui_capture_test.dart
/// 产出：test/ui/goldens/*.png（412×916 逻辑分辨率 @2x）
///
/// @Skip：依赖本机字体（C:/Windows/Fonts/msyh.ttc）与绝对路径，
/// 不进 CI——CI 无中文字体会渲染成豆腐块，断言也必失败。
@Skip('仅本机视觉评审采集，不进 CI')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipvault/app.dart';
import 'package:clipvault/clipboard/clipboard_watcher.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/core/backoff.dart';
import 'package:clipvault/core/error.dart';
import 'package:clipvault/data/database.dart';
import 'package:clipvault/data/history_repository.dart';
import 'package:clipvault/data/tables.dart' as tbl;
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/sharing/share_receiver.dart';
import 'package:clipvault/ui/downloads/downloads_screen.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';
import 'package:clipvault/ui/history/history_screen.dart';
import 'package:clipvault/ui/home/home_screen.dart';
import 'package:clipvault/ui/settings/settings_screen.dart';
import 'package:clipvault/ui/sheet/quality_sheet.dart';

// ---------------------------------------------------------------------------
// 字体加载（golden 默认 Ahem 方块字，必须注册真实字体）
// ---------------------------------------------------------------------------

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var loaded = 0;
  for (final p in paths) {
    final f = File(p);
    if (!f.existsSync()) continue;
    final bytes = f.readAsBytesSync();
    loader.addFont(Future.value(bytes.buffer.asByteData()));
    loaded++;
  }
  if (loaded > 0) await loader.load();
}

Future<void> _loadCaptureFonts() async {
  const sdk = 'D:/Program/flutter/bin/cache/artifacts/material_fonts';
  await _loadFont('Roboto', [
    '$sdk/roboto-regular.ttf',
    '$sdk/roboto-medium.ttf',
  ]);
  await _loadFont('MaterialIcons', ['$sdk/materialicons-regular.otf']);
  // 中文字体：微软雅黑（回退黑体/宋体）
  await _loadFont('CaptureCJK', [
    'C:/Windows/Fonts/msyh.ttc',
    'C:/Windows/Fonts/simhei.ttf',
    'C:/Windows/Fonts/simsun.ttc',
  ]);
}

ThemeData _captureTheme(Brightness b) => ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF00696F),
        brightness: b,
      ),
      fontFamily: 'CaptureCJK',
      fontFamilyFallback: const ['Roboto'],
    );

Future<void> _capture(
  WidgetTester tester,
  String name,
  Widget child, {
  Brightness brightness = Brightness.light,
  int extraPumps = 0,
}) async {
  tester.view.physicalSize = const Size(824, 1832);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: _captureTheme(brightness),
      darkTheme: _captureTheme(Brightness.dark),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      debugShowCheckedModeBanner: false,
      home: child,
    ),
  );
  for (var i = 0; i < extraPumps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

// ---------------------------------------------------------------------------
// 测试替身
// ---------------------------------------------------------------------------

class _HangingParser implements TweetParser {
  final Completer<ResolveResult> completer = Completer<ResolveResult>();
  @override
  Future<ResolveResult> resolve(String tweetId, {int videoIndex = 0}) =>
      completer.future;
}

class _NotFoundParser implements TweetParser {
  @override
  Future<ResolveResult> resolve(String tweetId, {int videoIndex = 0}) async {
    throw TweetNotFound();
  }
}

class _QueueReader implements ClipboardReader {
  _QueueReader(List<String?> reads) : q = List<String?>.of(reads);
  final List<String?> q;
  @override
  Future<String?> readText() async => q.isNotEmpty ? q.removeAt(0) : null;
}

class _AlwaysWifi implements ConnectivityChecker {
  const _AlwaysWifi();
  @override
  Future<bool> get isOnWifi async => true;
  @override
  Stream<bool> get onWifiChanged => const Stream<bool>.empty();
}

class _NoopCommands implements DownloadCommands {
  @override
  Future<DownloadEnqueueResult> enqueue({
    required String tweetId,
    required VideoVariant variant,
    required String tweetJson,
  }) async =>
      DownloadEnqueueResult.enqueued;
  @override
  Future<void> pause(int id) async {}
  @override
  Future<void> resume(int id) async {}
  @override
  Future<void> cancel(int id) async {}
  @override
  Future<void> retry(int id) async {}
}

const String _kUrl = 'https://x.com/historyinmemes/status/1790637656616943991';

List<Object> _homeOverrides({
  required TweetParser parser,
  ClipboardReader reader =
      const _EmptyReader(),
}) =>
    [
      tweetParserProvider.overrideWith((ref) => parser),
      parseRetryBackoffProvider.overrideWithValue(
        ExponentialBackoff(jitterFactory: (_) => Duration.zero),
      ),
      clipboardReaderProvider.overrideWithValue(reader),
      shareReceiverProvider.overrideWithValue(NoopShareReceiver()),
      downloadCommandsProvider.overrideWithValue(_NoopCommands()),
      downloadsWatchProvider.overrideWith((ref) => const Stream.empty()),
    ];

class _EmptyReader implements ClipboardReader {
  const _EmptyReader();
  @override
  Future<String?> readText() async => null;
}

// ---------------------------------------------------------------------------
// 数据样本
// ---------------------------------------------------------------------------

String _snapshotJson({String? text, String? author}) => jsonEncode({
      'tweetId': '1790637656616943991',
      'userName': author ?? '历史梗图仓库',
      'text': text ?? '示例推文正文：用于视觉评审的较长文案，观察两行截断与行高。',
      'thumbnailUrl': '',
      'durationMillis': 90000,
    });

VideoVariant _variant(int bitrate, int estBytes) => VideoVariant(
      contentType: VariantContentType.mp4,
      bitrate: bitrate,
      url:
          'https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/1280x720/x.mp4',
      width: 1280,
      height: 720,
      estimatedBytes: estBytes,
    );

TweetMeta _sheetTweet() => TweetMeta(
      tweetId: '1790637656616943991',
      userName: '历史梗图仓库',
      screenName: 'historyinmemes',
      avatarUrl: '',
      text: '示例推文正文：用于视觉评审的较长文案，观察两行截断与行高表现，'
          '同时看作者名与昵称的层次关系是否清晰可辨。',
      createdAt: DateTime(2026, 9, 25, 14, 30),
      thumbnailUrl: '',
      durationMillis: 90000,
      possiblySensitive: false,
      videoCount: 2,
      variants: [
        _variant(2176000, 24512000),
        _variant(832000, 9360000),
        _variant(288000, 3240000),
      ],
    );

List<TaskItem> _downloadItems() => [
      TaskItem(
        id: 1,
        tweetId: '1790637656616943991',
        status: tbl.DownloadStatus.running,
        qualityLabel: '720p (HD)',
        variantUrl: 'u',
        bytesTotal: 24512000,
        bytesDone: 12256000,
        speedBps: 1572864,
        activeMs: 83000,
        etaSec: 83,
        tweetJson: _snapshotJson(text: '正在下载的推文视频标题示例'),
        createdAt: DateTime(2026, 9, 25, 14, 28),
      ),
      TaskItem(
        id: 2,
        tweetId: '1790637656616943992',
        status: tbl.DownloadStatus.paused,
        qualityLabel: '1080p (Full HD)',
        variantUrl: 'u',
        bytesTotal: 40120000,
        bytesDone: 18900000,
        speedBps: 0,
        tweetJson: _snapshotJson(text: '已暂停的下载任务标题'),
        createdAt: DateTime(2026, 9, 25, 14, 20),
      ),
      TaskItem(
        id: 3,
        tweetId: '1790637656616943993',
        status: tbl.DownloadStatus.queued,
        qualityLabel: '480p (SD)',
        variantUrl: 'u',
        bytesTotal: 9360000,
        bytesDone: 0,
        speedBps: 0,
        tweetJson: _snapshotJson(text: '排队等待中的任务标题'),
        createdAt: DateTime(2026, 9, 25, 14, 25),
      ),
      TaskItem(
        id: 4,
        tweetId: '1790637656616943994',
        status: tbl.DownloadStatus.failed,
        qualityLabel: '720p (HD)',
        variantUrl: 'u',
        bytesTotal: 24512000,
        bytesDone: 1225600,
        speedBps: 0,
        errorCode: 'retryable',
        tweetJson: _snapshotJson(text: '失败任务标题（网络错误）'),
        createdAt: DateTime(2026, 9, 25, 13, 40),
      ),
      TaskItem(
        id: 5,
        tweetId: '1790637656616943995',
        status: tbl.DownloadStatus.completed,
        qualityLabel: '1080p (Full HD)',
        variantUrl: 'u',
        bytesTotal: 40120000,
        bytesDone: 40120000,
        speedBps: 0,
        albumSavedAt: DateTime(2026, 9, 24, 10, 0),
        filePath: '/data/downloads/x.mp4',
        tweetJson: _snapshotJson(text: '昨天完成并已入相册的历史条目'),
        createdAt: DateTime(2026, 9, 24, 10, 0),
      ),
      TaskItem(
        id: 6,
        tweetId: '1790637656616943996',
        status: tbl.DownloadStatus.completed,
        qualityLabel: '720p (HD)',
        variantUrl: 'u',
        bytesTotal: 24512000,
        bytesDone: 24512000,
        speedBps: 0,
        filePath: '/data/downloads/y.mp4',
        tweetJson: _snapshotJson(text: '未保存至相册的历史条目'),
        createdAt: DateTime(2026, 9, 23, 9, 0),
      ),
    ];

// ---------------------------------------------------------------------------
// 采集用例
// ---------------------------------------------------------------------------

void main() {
  setUpAll(_loadCaptureFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('home_idle：空态引导卡（首次使用视角）', (tester) async {
    await _capture(
      tester,
      'home_idle',
      ProviderScope(
        overrides: [..._homeOverrides(parser: _HangingParser()).cast()],
        child: const HomeScreen(),
      ),
    );
  });

  testWidgets('home_parsing：剪贴板横幅 + 一次性解释 + 解析骨架卡', (tester) async {
    tester.view.physicalSize = const Size(824, 1832);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'clipboard.explained': false,
    });
    final reader = _QueueReader([_kUrl]);
    await tester.pumpWidget(
      MaterialApp(
        theme: _captureTheme(Brightness.light),
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        debugShowCheckedModeBanner: false,
        home: ProviderScope(
          overrides: [..._homeOverrides(parser: _HangingParser(), reader: reader).cast()],
          child: const HomeScreen(),
        ),
      ),
    );
    // 触发 resume → 剪贴板横幅出现
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    // 填入链接并开始解析（悬挂解析器 → 骨架卡持续）
    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home_parsing.png'),
    );
  });

  testWidgets('home_error：E04 错误卡片', (tester) async {
    tester.view.physicalSize = const Size(824, 1832);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: _captureTheme(Brightness.light),
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        debugShowCheckedModeBanner: false,
        home: ProviderScope(
          overrides: [..._homeOverrides(parser: _NotFoundParser()).cast()],
          child: const HomeScreen(),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), _kUrl);
    await tester.tap(find.text(AppStrings.homePasteAndParse));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home_error.png'),
    );
  });

  testWidgets('quality_sheet：清晰度选择底部弹层', (tester) async {
    tester.view.physicalSize = const Size(824, 1832);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: _captureTheme(Brightness.light),
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showQualitySheet(
                  context,
                  tweet: _sheetTweet(),
                  onStartDownload: (_, _) {},
                  onSwitchVideo: (_) async => ResolveResult(
                    tweet: _sheetTweet(),
                    parserVersion: 'syndication-v1',
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/quality_sheet.png'),
    );
  });

  testWidgets('downloads：四分区任务列表', (tester) async {
    await _capture(
      tester,
      'downloads',
      ProviderScope(
        overrides: [
          connectivityCheckerProvider.overrideWithValue(const _AlwaysWifi()),
          downloadsWatchProvider.overrideWith(
            (ref) => Stream.value(_downloadItems()),
          ),
        ],
        child: const DownloadsScreen(),
      ),
      extraPumps: 2,
    );
  });

  testWidgets('downloads_cooldown：429 冷却横幅 + 限速等待标签', (tester) async {
    await _capture(
      tester,
      'downloads_cooldown',
      ProviderScope(
        overrides: [
          connectivityCheckerProvider.overrideWithValue(const _AlwaysWifi()),
          downloadsWatchProvider.overrideWith(
            (ref) => Stream.value(_downloadItems()),
          ),
          coolingProvider.overrideWith(
            (ref) => Stream.value(
              DateTime.now().add(const Duration(seconds: 28)),
            ),
          ),
        ],
        child: const DownloadsScreen(),
      ),
      extraPumps: 2,
    );
  });

  testWidgets('settings：我的 Tab', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'disclaimer.version': 1,
      'settings.concurrency': 2,
      'settings.qualityMode': 'highest',
      'settings.wifiOnly': false,
    });
    await _capture(
      tester,
      'settings',
      const ProviderScope(child: SettingsScreen()),
      extraPumps: 6,
    );
  });

  testWidgets('history：历史详情页', (tester) async {
    final db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    addTearDown(db.close);
    final repo = HistoryRepository(db);
    final row = await repo.createTask(
      DownloadRecordsCompanion.insert(
        tweetId: '1790637656616943991',
        variantUrl: 'https://video.twimg.com/x.mp4',
        contentType: 'mp4',
        bitrate: 2176000,
        qualityLabel: '720p (HD)',
        status: tbl.DownloadStatus.completed.name,
        tweetJson: _snapshotJson(
          text: '历史详情页的推文标题示例：观察卡片排版与操作按钮组的布局层次。',
          author: '历史梗图仓库',
        ),
        filePath: Value('/data/downloads/x.mp4'),
      ),
    );
    final item = mapRecordToTaskItem(row);
    await _capture(
      tester,
      'history',
      ProviderScope(
        overrides: [historyRepositoryProvider.overrideWithValue(repo)],
        child: HistoryScreen(item: item),
      ),
      extraPumps: 3,
    );
  });

  testWidgets('disclaimer_gate：品牌闸门页 + 首启协议弹窗', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'disclaimer.version': 0,
    });
    tester.view.physicalSize = const Size(824, 1832);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: _captureTheme(Brightness.light),
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        debugShowCheckedModeBanner: false,
        home: const ProviderScope(child: DisclaimerGate(child: SizedBox())),
      ),
    );
    await tester.pump();
    // 弹窗延后 500ms（主题 G）+ 弹窗入场动画
    await tester.pump(const Duration(milliseconds: 700));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/disclaimer_gate.png'),
    );
  });

  testWidgets('home_dark：深色模式首页', (tester) async {
    await _capture(
      tester,
      'home_dark',
      ProviderScope(
        overrides: [..._homeOverrides(parser: _HangingParser()).cast()],
        child: const HomeScreen(),
      ),
      brightness: Brightness.dark,
    );
  });

  testWidgets('downloads_dark：深色模式下载列表', (tester) async {
    await _capture(
      tester,
      'downloads_dark',
      ProviderScope(
        overrides: [
          connectivityCheckerProvider.overrideWithValue(const _AlwaysWifi()),
          downloadsWatchProvider.overrideWith(
            (ref) => Stream.value(_downloadItems()),
          ),
        ],
        child: const DownloadsScreen(),
      ),
      brightness: Brightness.dark,
      extraPumps: 2,
    );
  });
}
