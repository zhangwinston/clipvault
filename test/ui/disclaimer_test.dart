// 免责声明闸门 widget 测试（DESIGN §11.2 / §8.3）：
// 首启强制弹窗 / 未勾选时同意不可用 / 不同意退出（SystemNavigator.pop）/
// 同意后写入版本与时间戳且不再弹 / 版本升级重弹（版本化断言）/
// 分享冷启动门禁：未同意前 pending 分享链接不得触发解析（review C1）。
// shared_preferences 走 setMockInitialValues，离线可跑。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipvault/app.dart';
import 'package:clipvault/clipboard/clipboard_watcher.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/settings/settings_controller.dart';
import 'package:clipvault/sharing/share_receiver.dart';
import 'package:clipvault/ui/common/parse_skeleton.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';
import 'package:clipvault/ui/home/home_screen.dart' show tweetParserProvider;

class _NullReader implements ClipboardReader {
  @override
  Future<String?> readText() async => null;
}

class _NullCommands implements DownloadCommands {
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

/// 携带 pending 冷启动分享文本的假接收器（review C1 分享门禁场景）
class _FakeShareReceiver implements ShareReceiver {
  _FakeShareReceiver(this.initial);

  final String? initial;

  @override
  Future<String?> initialText() async => initial;

  @override
  Stream<String> sharedText() => const Stream<String>.empty();

  @override
  void dispose() {}
}

/// 挂起的假解析器：resolve 永不完成（解析中骨架持续），只记录调用
class _PendingParser implements TweetParser {
  final List<String> requestedIds = [];

  @override
  Future<ResolveResult> resolve(String tweetId, {int videoIndex = 0}) {
    requestedIds.add(tweetId);
    return Completer<ResolveResult>().future;
  }
}

Widget _gateApp({
  ShareReceiver? shareReceiver,
  _PendingParser? parser,
}) {
  return ProviderScope(
    overrides: [
      if (parser != null)
        tweetParserProvider.overrideWith((ref) => parser),
      clipboardReaderProvider.overrideWithValue(_NullReader()),
      shareReceiverProvider.overrideWithValue(
        shareReceiver ?? NoopShareReceiver(),
      ),
      downloadCommandsProvider.overrideWithValue(_NullCommands()),
      downloadsWatchProvider.overrideWith((ref) => const Stream.empty()),
    ],
    child: const MaterialApp(home: DisclaimerGate(child: HomeShell())),
  );
}

Future<void> _pumpGate(WidgetTester tester, {ShareReceiver? shareReceiver}) async {
  await tester.pumpWidget(_gateApp(shareReceiver: shareReceiver));
  await tester.pump(); // 设置异步加载
  await tester.pump(); // 闸门 post-frame 弹窗
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('首启强制弹窗：条款可见且未同意前不展示首页内容交互', (tester) async {
    await _pumpGate(tester);
    // 精确断言版本化标题：textContaining(使用协议) 会同时命中
    // 复选框文案「我已阅读并同意《使用协议》」造成误报
    expect(
      find.text('${AppStrings.disclaimerTitle}（v$kCurrentDisclaimerVersion）'),
      findsOneWidget,
    );
    expect(find.text(AppStrings.disclaimerBody), findsOneWidget);
    expect(find.byType(Checkbox), findsOneWidget);
  });

  testWidgets('未勾选时点击同意无效，不写偏好', (tester) async {
    await _pumpGate(tester);

    await tester.tap(find.text(AppStrings.disclaimerAgree));
    await tester.pump();

    // 弹窗仍在，偏好未写
    expect(find.text(AppStrings.disclaimerBody), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(kPrefDisclaimerVersion), isNull);
  });

  testWidgets('勾选后同意：写版本+时间戳并放行', (tester) async {
    await _pumpGate(tester);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text(AppStrings.disclaimerAgree));
    await tester.pump();
    await tester.pump(); // 异步落偏好 + 闸门状态刷新

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(kPrefDisclaimerVersion), kCurrentDisclaimerVersion);
    expect(prefs.getInt(kPrefDisclaimerAcceptedAt), isNotNull);
    // 弹窗关闭，主壳可见
    expect(find.text(AppStrings.disclaimerBody), findsNothing);
    expect(find.text(AppStrings.tabHome), findsOneWidget);
  });

  testWidgets('不同意 → 退出（SystemNavigator.pop）', (tester) async {
    final platformCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call.method);
      return null;
    });

    await _pumpGate(tester);
    await tester.tap(find.text(AppStrings.disclaimerDecline));
    await tester.pump();

    expect(platformCalls, contains('SystemNavigator.pop'));

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('已同意当前版本 → 不再弹窗，直达主壳', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kPrefDisclaimerVersion: kCurrentDisclaimerVersion,
      kPrefDisclaimerAcceptedAt: 1700000000000,
    });
    await _pumpGate(tester);

    expect(find.text(AppStrings.disclaimerBody), findsNothing);
    expect(find.text(AppStrings.tabHome), findsOneWidget);
  });

  testWidgets('条款版本升级（已存版本落后）→ 重新弹窗', (tester) async {
    // 模拟旧版本已同意（v0 = 从未同意过条款），新版本发布后重弹
    SharedPreferences.setMockInitialValues(<String, Object>{
      kPrefDisclaimerVersion: 0,
      kPrefDisclaimerAcceptedAt: 1,
    });
    await _pumpGate(tester);

    // 同上：精确匹配版本化标题，避免复选框文案的子串误命中
    expect(
      find.text('${AppStrings.disclaimerTitle}（v$kCurrentDisclaimerVersion）'),
      findsOneWidget,
    );
    // C1 修复后闸门未放行前不挂载主壳（原断言「主壳在弹窗之下仍构建」
    // 编码的正是分享冷启动绕过缺陷：HomeShell 已 initState 并消费分享流）
    expect(find.text(AppStrings.tabHome), findsNothing);
  });

  testWidgets('分享冷启动门禁：未同意前 pending 链接不解析，同意后放行（review C1）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final parser = _PendingParser();
    await tester.pumpWidget(_gateApp(
      shareReceiver: _FakeShareReceiver(
        'https://x.com/someone/status/1790637656616943991?s=20',
      ),
      parser: parser,
    ));
    await tester.pump(); // 设置异步加载
    await tester.pump(); // 闸门 post-frame 弹窗
    await tester.pump(const Duration(milliseconds: 300)); // 分享 initialText 异步链

    // 未同意：弹窗在场，主壳未挂载，pending 分享未被消费——零解析请求
    expect(find.text(AppStrings.disclaimerBody), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(parser.requestedIds, isEmpty);

    // 勾选同意 → 闸门放行 → HomeScreen 才 initState 消费 pending 分享
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text(AppStrings.disclaimerAgree));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(AppStrings.disclaimerBody), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(parser.requestedIds, contains('1790637656616943991'));
    // 解析中骨架卡片持续（pending 解析器永不完成）
    expect(find.byType(ParseSkeleton), findsOneWidget);
  });

  testWidgets('重看入口：设置页可再次打开条款弹窗', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kPrefDisclaimerVersion: kCurrentDisclaimerVersion,
      kPrefDisclaimerAcceptedAt: 1700000000000,
    });
    await _pumpGate(tester);
    expect(find.text(AppStrings.disclaimerBody), findsNothing);

    // 切到「我的」Tab，点重看入口（不用 pumpAndSettle：下载 Tab 有常驻加载动画）
    await tester.tap(find.text(AppStrings.tabSettings));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(AppStrings.settingsDisclaimerRevisit), findsOneWidget);
    await tester.tap(find.text(AppStrings.settingsDisclaimerRevisit));
    await tester.pump();
    expect(find.text(AppStrings.disclaimerBody), findsOneWidget);
  });
}
