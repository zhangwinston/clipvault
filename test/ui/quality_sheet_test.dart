// 清晰度 Sheet widget 测试（DESIGN §11.2）：
// 变体降序排列 / 分辨率标签 / 码率+预估体积+MP4 标注 / 默认最高码率高亮 /
// 多视频 Chip 切换 / 开始下载回调。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/ui/sheet/quality_sheet.dart';

VideoVariant _variant(int bitrate, int w, int h) => VideoVariant(
      contentType: VariantContentType.mp4,
      bitrate: bitrate,
      url: 'https://video.twimg.com/ext_tw_video/vid/avc1/${w}x$h/x.mp4',
      width: w,
      height: h,
      // 与生产模型一致（models.dart：bitrate × durationMillis ~/ 8000）：
      // 90s × 2176000 bps / 8 ≈ 24.5 MB，对应 DESIGN §4.2 行模板示例量级；
      // 误用 ~/ 8 会放大 1000 倍变成 22.8 GB，行内永远不含「MB」
      estimatedBytes: bitrate * 90000 ~/ 8000,
    );

TweetMeta _meta(List<VideoVariant> variants, {int videoCount = 1}) => TweetMeta(
      tweetId: '1790637656616943991',
      userName: '测试作者',
      screenName: 'tester',
      avatarUrl: '',
      text: '多码率测试推文',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      thumbnailUrl: '',
      durationMillis: 90000,
      possiblySensitive: false,
      videoCount: videoCount,
      variants: variants,
    );

Future<void> _pumpSheet(
  WidgetTester tester, {
  required TweetMeta tweet,
  Future<ResolveResult> Function(int videoIndex)? onSwitchVideo,
  required void Function(VideoVariant, int) onStart,
}) async {
  // 手机比例视口：预览卡（16:9）+ 变体列表 + 按钮全部落入测试画面
  tester.view.physicalSize = const Size(412, 916);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: QualitySheet(
            tweet: tweet,
            onSwitchVideo: onSwitchVideo,
            onStartDownload: onStart,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('变体按码率降序排列且默认高亮最高档', (tester) async {
    // 故意乱序传入，Sheet 应降序展示（防御性排序）
    final tweet = _meta([_variant(832000, 640, 360), _variant(2176000, 1280, 720)]);
    VideoVariant? picked;
    await _pumpSheet(tester, tweet: tweet, onStart: (v, _) => picked = v);
    await tester.pumpAndSettle();

    // 默认选中最高码率（720p）
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    final firstSubtitle = tester.widget<ListTile>(find.byType(ListTile).first);
    expect(firstSubtitle.selected, isTrue);

    await tester.tap(find.text(AppStrings.qualityStartDownload));
    await tester.pump();
    expect(picked?.bitrate, 2176000);
  });

  testWidgets('行模板包含分辨率标签、码率、预估体积与 MP4 标注', (tester) async {
    final tweet = _meta([_variant(2176000, 1280, 720)]);
    await _pumpSheet(tester, tweet: tweet, onStart: (_, _) {});
    await tester.pumpAndSettle();

    expect(find.text('720p (HD)'), findsOneWidget);
    expect(find.textContaining('2.18 ${AppStrings.unitMbps}'), findsOneWidget);
    expect(find.textContaining(AppStrings.unitMB), findsOneWidget);
    expect(find.textContaining(AppStrings.tagMp4), findsOneWidget);
  });

  testWidgets('点击低档行切换选中并回调该变体', (tester) async {
    final tweet = _meta([_variant(2176000, 1280, 720), _variant(832000, 640, 360)]);
    VideoVariant? picked;
    await _pumpSheet(tester, tweet: tweet, onStart: (v, _) => picked = v);
    await tester.pumpAndSettle();

    await tester.tap(find.text('360p'));
    await tester.pump();
    final selectedRow = tester.widget<ListTile>(find.byType(ListTile).last);
    expect(selectedRow.selected, isTrue);

    await tester.tap(find.text(AppStrings.qualityStartDownload));
    await tester.pump();
    expect(picked?.bitrate, 832000);
  });

  testWidgets('多视频推文显示 Chip，切换经 onSwitchVideo 重新解析', (tester) async {
    final tweet = _meta([_variant(2176000, 1280, 720)], videoCount: 2);
    VideoVariant? picked;
    final switchCalls = <int>[];
    await _pumpSheet(
      tester,
      tweet: tweet,
      onSwitchVideo: (videoIndex) async {
        switchCalls.add(videoIndex);
        return ResolveResult(
          tweet: _meta([_variant(832000, 640, 360)]),
          parserVersion: 'syndication-v1',
        );
      },
      onStart: (v, i) => picked = v,
    );
    await tester.pumpAndSettle();

    expect(find.text('${AppStrings.qualityVideoChip}1'), findsOneWidget);
    expect(find.text('${AppStrings.qualityVideoChip}2'), findsOneWidget);
    expect(find.text('720p (HD)'), findsOneWidget);

    // 切到视频 2 → onSwitchVideo(1) → 列表变为 360p 档
    await tester.tap(find.text('${AppStrings.qualityVideoChip}2'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(switchCalls, contains(1));
    expect(find.text('360p'), findsOneWidget);

    await tester.tap(find.text(AppStrings.qualityStartDownload));
    await tester.pump();
    expect(picked?.bitrate, 832000);
  });

  testWidgets('初始高亮档可由调用方指定（省流 720p 偏好）', (tester) async {
    // 降序展示为 1080p / 720p / 360p；initialVariantIndex=1 → 默认选中 720p
    final tweet = _meta([
      _variant(832000, 640, 360),
      _variant(2176000, 1280, 720),
      _variant(3200000, 1920, 1080),
    ]);
    VideoVariant? picked;
    tester.view.physicalSize = const Size(412, 916);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: QualitySheet(
              tweet: tweet,
              onStartDownload: (v, _) => picked = v,
              initialVariantIndex: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final secondRow = tester.widget<ListTile>(find.byType(ListTile).at(1));
    expect(secondRow.selected, isTrue);

    await tester.tap(find.text(AppStrings.qualityStartDownload));
    await tester.pump();
    expect(picked?.bitrate, 2176000); // 720p 档
  });

  testWidgets('连点「开始下载」只触发一次回调且 Sheet 关闭（review C2）', (tester) async {
    final tweet = _meta([_variant(2176000, 1280, 720)]);
    var startCalls = 0;
    tester.view.physicalSize = const Size(412, 916);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 经 showModalBottomSheet 宿主（真实路由：点击后 Sheet 应被 pop）
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showQualitySheet(
                  context,
                  tweet: tweet,
                  onStartDownload: (_, _) => startCalls++,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.qualitySheetTitle), findsOneWidget);

    // 同帧内快速连点两次（第二次命中已禁用/已提交的按钮）
    final button = find.text(AppStrings.qualityStartDownload);
    await tester.tap(button);
    await tester.tap(button, warnIfMissed: false);
    await tester.pump();

    expect(startCalls, 1);
    // Sheet 关闭（pop 动画收尾）
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.qualitySheetTitle), findsNothing);
  });
}
