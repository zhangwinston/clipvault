// App 启动冒烟 widget 测试（替代 flutter create 计数器模板）：
// 覆盖 main 入口装配后的首帧路径——免责已同意 → 3 Tab 主壳完整构建；
// 另覆盖 MaterialApp zh 本地化代理（Material 内置文案中文化）。
// 全部引擎/仓库/解析器经 ProviderScope overrides 注入假实现，不触真网络与真插件。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipvault/app.dart';
import 'package:clipvault/clipboard/clipboard_watcher.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/core/error.dart';
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/sharing/share_receiver.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';
import 'package:clipvault/ui/home/home_screen.dart' show tweetParserProvider;

class _NullReader implements ClipboardReader {
  @override
  Future<String?> readText() async => null;
}

class _NullParser implements TweetParser {
  @override
  Future<ResolveResult> resolve(String tweetId, {int videoIndex = 0}) async =>
      throw NetworkTimeout();
}

VideoVariant _variant(int bitrate, int w, int h) => VideoVariant(
      contentType: VariantContentType.mp4,
      bitrate: bitrate,
      url: 'https://video.twimg.com/ext_tw_video/vid/avc1/${w}x$h/x.mp4',
      width: w,
      height: h,
      estimatedBytes: bitrate * 90000 ~/ 8000,
    );

/// 固定成功解析的假解析器（本地化冒烟用）
class _OkParser implements TweetParser {
  @override
  Future<ResolveResult> resolve(String tweetId, {int videoIndex = 0}) async =>
      ResolveResult(
        tweet: TweetMeta(
          tweetId: tweetId,
          userName: '测试作者',
          screenName: 'tester',
          avatarUrl: '',
          text: '本地化冒烟',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          thumbnailUrl: '',
          durationMillis: 90000,
          possiblySensitive: false,
          videoCount: 1,
          variants: [_variant(2176000, 1280, 720)],
        ),
        parserVersion: 'fake-v1',
      );
}

class _NullCommands implements DownloadCommands {
  @override
  Future<DownloadEnqueueResult> enqueue({
    required String tweetId,
    required VideoVariant variant,
    required String tweetJson,
  }) async => DownloadEnqueueResult.enqueued;

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> retry(int id) async {}
}

void main() {
  testWidgets('应用启动冒烟：免责放行后 3 Tab 主壳完整构建', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'disclaimer.version': 1,
      'disclaimer.acceptedAt': 1700000000000,
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // tweetParserProvider 为 FutureProvider（端点配置仓库接线），
          // 测试以 overrideWith 同步注入假实现
          tweetParserProvider.overrideWith((ref) => _NullParser()),
          clipboardReaderProvider.overrideWithValue(_NullReader()),
          shareReceiverProvider.overrideWithValue(NoopShareReceiver()),
          downloadCommandsProvider.overrideWithValue(_NullCommands()),
          downloadsWatchProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: const XdownApp(),
      ),
    );
    await tester.pump(); // 设置异步恢复
    await tester.pump(); // 首帧完成

    // 3 Tab 导航完整（IndexedStack 内对应屏 AppBar 标题同名 → 至少命中导航标签）
    expect(find.text(AppStrings.tabHome), findsWidgets);
    expect(find.text(AppStrings.tabDownloads), findsWidgets);
    expect(find.text(AppStrings.tabSettings), findsWidgets);

    // 首页主控件就位（输入框 + 解析按钮）
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text(AppStrings.homeParse), findsOneWidget);

    // 免责已同意 → 不弹条款
    expect(find.text(AppStrings.disclaimerBody), findsNothing);

    // Tab 切换可用
    await tester.tap(find.text(AppStrings.tabSettings));
    await tester.pump();
    expect(find.text(AppStrings.settingsDisclaimerRevisit), findsOneWidget);
  });

  testWidgets('zh 本地化代理：清晰度 Sheet 关闭按钮 tooltip 为中文', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'disclaimer.version': 1,
      'disclaimer.acceptedAt': 1700000000000,
    });
    tester.view.physicalSize = const Size(412, 916);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tweetParserProvider.overrideWith((ref) => _OkParser()),
          clipboardReaderProvider.overrideWithValue(_NullReader()),
          shareReceiverProvider.overrideWithValue(NoopShareReceiver()),
          downloadCommandsProvider.overrideWithValue(_NullCommands()),
          downloadsWatchProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: const XdownApp(),
      ),
    );
    await tester.pump(); // 设置异步恢复
    await tester.pump(); // 首帧完成

    // 触发一次成功解析 → 清晰度 Sheet 弹出
    await tester.enterText(
      find.byType(TextField),
      'https://x.com/someone/status/1790637656616943991?s=20',
    );
    await tester.tap(find.text(AppStrings.homeParse));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(AppStrings.qualitySheetTitle), findsOneWidget);

    // Material 内置文案随 zh 代理中文化（GlobalMaterialLocalizations）
    expect(find.byTooltip('关闭'), findsOneWidget);
  });
}
