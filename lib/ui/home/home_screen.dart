/// 首页（DESIGN §7.1-1）：
/// 大号 URL 输入框（清空 ×、一键粘贴）+「解析」主按钮；
/// 剪贴板 resume 命中 → 顶部内联横幅（同链接去重，§4.1-2）；
/// 解析中骨架卡片 + 耗时计时；解析成功 → QualitySheet → 开始下载 → toast；
/// 最近解析卡片（内存态）+ 七类错误视图。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/clipboard/clipboard_watcher.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/core/backoff.dart';
import 'package:clipvault/core/error.dart';
import 'package:clipvault/core/url_extract.dart';
import 'package:clipvault/parse/endpoint_config.dart';
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/parse/syndication_client.dart';
import 'package:clipvault/parse/syndication_parser.dart';
import 'package:clipvault/settings/settings_controller.dart';
import 'package:clipvault/sharing/share_receiver.dart';
import 'package:clipvault/ui/common/error_views.dart';
import 'package:clipvault/ui/common/parse_skeleton.dart';
import 'package:clipvault/ui/common/preview_card.dart';
import 'package:clipvault/ui/downloads/task_tile.dart';
import 'package:clipvault/ui/sheet/quality_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首页解析状态（内存态）
class HomeParseState {
  const HomeParseState({
    this.phase = HomePhase.idle,
    this.error,
    this.result,
    this.recent = const <TweetMeta>[],
  });

  final HomePhase phase;
  final ParseError? error;
  final ResolveResult? result;
  final List<TweetMeta> recent;

  HomeParseState copyWith({
    HomePhase? phase,
    ParseError? error,
    ResolveResult? result,
    List<TweetMeta>? recent,
    bool clearError = false,
    bool clearResult = false,
  }) {
    return HomeParseState(
      phase: phase ?? this.phase,
      error: clearError ? null : (error ?? this.error),
      result: clearResult ? null : (result ?? this.result),
      recent: recent ?? this.recent,
    );
  }
}

enum HomePhase { idle, parsing, error, resolved }

/// 首页解析控制器（Notifier）：URL 校验 → TweetParser.resolve → 状态落位
class HomeParseController extends Notifier<HomeParseState> {
  @override
  HomeParseState build() => const HomeParseState();

  /// 当前解析器（生产按端点配置仓库构建；测试 override tweetParserProvider）
  Future<TweetParser> get _parser => ref.read(tweetParserProvider.future);

  /// 发起解析（粘贴/横幅/分享统一入口）
  Future<void> parse(String input) async {
    final text = input.trim();
    if (text.isEmpty) {
      state = const HomeParseState().copyWith(phase: HomePhase.idle);
      return;
    }
    final tweetId = extractTweetId(text);
    if (tweetId == null) {
      // E01：零网络请求（§6.5）
      state = state.copyWith(phase: HomePhase.error, error: UrlInvalid(), clearResult: true);
      return;
    }
    state = state.copyWith(phase: HomePhase.parsing, clearError: true, clearResult: true);
    ParseError? lastError;
    try {
      final result = await _resolveWithRetry(tweetId);
      final recent = List<TweetMeta>.of(state.recent)
        ..insert(0, result.tweet);
      if (recent.length > 5) recent.removeRange(5, recent.length);
      state = state.copyWith(
        phase: HomePhase.resolved,
        result: result,
        recent: recent.toList(growable: false),
      );
      return;
    } on ParseError catch (e) {
      lastError = e;
    } catch (_) {
      // 兜底归 E02（_resolveWithRetry 内已归一，此处防御）
      lastError = NetworkTimeout();
    }
    state = state.copyWith(
      phase: HomePhase.error,
      error: lastError,
      clearResult: true,
    );
  }

  /// 解析编排（PRD §5 / DESIGN §6.5/§6.7）：
  /// - E02（NetworkTimeout）：指数退避自动重试 3 次（800ms×2^n+抖动），
  ///   重试期间 phase 保持 parsing（骨架卡片持续），耗尽才透出错误+重试按钮；
  /// - E03/E04/E06 等非网络类不自动重试；
  /// - E07（EndpointDrift）：经端点配置仓库 onEndpointDrift() 刷新，
  ///   刷新到新配置则 invalidate 重建解析器后重试一次（免发版自愈链路）。
  Future<ResolveResult> _resolveWithRetry(String tweetId) async {
    final backoff = ref.read(parseRetryBackoffProvider);
    var networkAttempts = 0;
    while (true) {
      if (networkAttempts > 0) {
        // 退避等待（fakeAsync/测试伪时钟可确定性断言间隔）
        await backoff.wait(networkAttempts - 1);
      }
      var driftAttempts = 0;
      while (true) {
        final parser = await _parser;
        try {
          return await parser.resolve(tweetId);
        } on EndpointDrift {
          driftAttempts++;
          if (driftAttempts > 1) rethrow; // 至多重建重试一次
          final repo = await ref.read(endpointConfigRepositoryProvider.future);
          final refreshed = await repo.onEndpointDrift();
          if (!refreshed) rethrow; // 无新配置：透出 E07
          ref.invalidate(tweetParserProvider); // 新配置 → 重建解析器
          continue;
        } on ParseError catch (e) {
          if (e is NetworkTimeout && backoff.hasRetryLeft(networkAttempts)) {
            networkAttempts++;
            break; // 退避后重试（骨架持续）
          }
          rethrow; // 非网络类 / 退避耗尽：透出
        } catch (_) {
          // 非 ParseError 的网络/IO 异常统一归 E02（§6.6）后再走退避判定
          if (backoff.hasRetryLeft(networkAttempts)) {
            networkAttempts++;
            break;
          }
          throw NetworkTimeout();
        }
      }
    }
  }

  void reset() {
    state = state.copyWith(phase: HomePhase.idle, clearError: true, clearResult: true);
  }
}

final NotifierProvider<HomeParseController, HomeParseState> homeParseControllerProvider =
    NotifierProvider<HomeParseController, HomeParseState>(HomeParseController.new);

/// 解析退避策略注入点（默认 800ms×2^n+抖动 ×3，DESIGN §4.3/§6.5）；
/// 测试 override 注入零抖动工厂即可确定性断言重试次数与间隔。
final Provider<ExponentialBackoff> parseRetryBackoffProvider =
    Provider<ExponentialBackoff>((ref) => ExponentialBackoff());

/// 端点配置仓库（DESIGN §6.7 加载顺序的生产装配）：
/// 内置 assets（rootBundle 加载 assets/config/endpoints.json）→
/// prefs 缓存（版本更高原子替换）→ 后台远端拉取（remoteUrl 默认空=关闭）。
final FutureProvider<EndpointConfigRepository> endpointConfigRepositoryProvider =
    FutureProvider<EndpointConfigRepository>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final repo = EndpointConfigRepository(
    dio: Dio(),
    prefs: prefs,
    assetLoader: (path) => rootBundle.loadString(path),
  );
  await repo.load();
  return repo;
});

/// 解析器注入点：生产用 SyndicationParser 主实现，端点配置取自配置仓库
/// 当前生效版本（§6.7；E07 刷新成功后 invalidate 重建，新配置生效）。
/// 测试以 overrideWith 注入假解析器（FutureProvider 接受同步返回值）。
final FutureProvider<TweetParser> tweetParserProvider =
    FutureProvider<TweetParser>((ref) async {
  final repo = await ref.watch(endpointConfigRepositoryProvider.future);
  return SyndicationParser(
    client: SyndicationClient(dio: Dio()),
    config: repo.current,
  );
});

/// 首页
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final TextEditingController _input = TextEditingController();
  StreamSubscription<String>? _shareSub;
  bool _sheetOpenedFor = false;
  // 在 initState 中取一次实例，避免 dispose 阶段访问 ref
  late final ClipboardWatcher _clipboardWatcher;

  @override
  void initState() {
    super.initState();
    // 挂载剪贴板生命周期观察者（resume 时机读取，§8.2）
    _clipboardWatcher = ref.read(clipboardWatcherProvider.notifier);
    WidgetsBinding.instance.addObserver(_clipboardWatcher);
    // P1：系统分享文本 → 自动填充并解析（§7 导航流）
    final share = ref.read(shareReceiverProvider);
    _shareSub = share.sharedText().listen(_onSharedText);
    share.initialText().then((value) {
      if (value != null && value.isNotEmpty) _onSharedText(value);
    });
  }

  void _onSharedText(String text) {
    if (!mounted) return;
    _input.text = text;
    ref.read(homeParseControllerProvider.notifier).parse(text);
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    WidgetsBinding.instance.removeObserver(_clipboardWatcher);
    _input.dispose();
    super.dispose();
  }

  Future<void> _parseInput() async {
    await ref.read(homeParseControllerProvider.notifier).parse(_input.text);
  }

  Future<void> _pasteFromClipboard() async {
    final text = await ref.read(clipboardReaderProvider).readText();
    if (text != null && text.isNotEmpty && mounted) {
      setState(() => _input.text = text);
    }
  }

  Future<void> _startDownload(VideoVariant variant, String tweetId, TweetMeta tweet) async {
    // 快照 tweetJson（历史页离线渲染，§4.5）：TweetMeta.toJson（§5.1 契约）
    // + 选中变体（含 qualityLabel）。
    final snapshot = jsonEncode(<String, Object?>{
      ...tweet.toJson(),
      'selectedVariant': variant.toJson(),
    });
    final result = await ref
        .read(downloadCommandsProvider)
        .enqueue(tweetId: tweetId, variant: variant, tweetJson: snapshot);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(switch (result) {
          // 业务键重复：同 (tweetId, bitrate) 已有活动任务
          DownloadEnqueueResult.duplicate => AppStrings.taskAlreadyQueued,
          // 仅 Wi-Fi 偏好挂起：已入等待队列，网络恢复自动继续
          DownloadEnqueueResult.waitingWifi =>
            AppStrings.taskWaitingWifi,
          DownloadEnqueueResult.enqueued => AppStrings.toastEnqueued,
        }),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parseState = ref.watch(homeParseControllerProvider);
    final pendingClipboard = ref.watch(clipboardWatcherProvider);
    // 首选清晰度偏好（§3.2 省流 720p）：build 期 watch 触发设置异步加载，
    // 解析成功弹 Sheet 时取值已就绪（未加载/失败回落 highest）
    final qualityMode =
        ref.watch(settingsControllerProvider).value?.qualityMode ??
            kQualityModeHighest;

    // 解析成功 → 自动弹出清晰度 Sheet（每次成功只弹一次）
    ref.listen<HomeParseState>(homeParseControllerProvider, (previous, next) {
      if (next.phase == HomePhase.resolved && previous?.result != next.result && !_sheetOpenedFor) {
        _sheetOpenedFor = true;
        _openQualitySheet(next.result!, qualityMode);
      } else if (next.phase != HomePhase.resolved) {
        _sheetOpenedFor = false;
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.appName)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            // 剪贴板内联横幅（点击立即解析；§1.3-#4 横幅而非浮窗）
            if (pendingClipboard != null)
              Material(
                color: scheme.secondaryContainer,
                child: InkWell(
                  onTap: () {
                    ref.read(clipboardWatcherProvider.notifier).consume();
                    _input.text = pendingClipboard;
                    _parseInput();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(
                      children: [
                        Icon(Icons.content_paste_search, color: scheme.onSecondaryContainer),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            AppStrings.clipboardBanner,
                            style: TextStyle(color: scheme.onSecondaryContainer),
                          ),
                        ),
                        IconButton(
                          tooltip: AppStrings.homeClear,
                          onPressed: () => ref.read(clipboardWatcherProvider.notifier).consume(),
                          icon: Icon(Icons.close, color: scheme.onSecondaryContainer),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                controller: _input,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: AppStrings.homeInputHint,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: AppStrings.homeClear,
                    onPressed: () => setState(() => _input.clear()),
                    icon: const Icon(Icons.clear),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _parseInput,
                      icon: const Icon(Icons.link),
                      label: const Text(AppStrings.homeParse),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pasteFromClipboard,
                      icon: const Icon(Icons.content_paste),
                      label: const Text(AppStrings.homePaste),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            switch (parseState.phase) {
              HomePhase.idle => const SizedBox.shrink(),
              HomePhase.parsing => const ParseSkeleton(),
              HomePhase.error => ParseErrorView(
                  error: parseState.error ?? NetworkTimeout(),
                  onRetry: _parseInput,
                ),
              HomePhase.resolved => PreviewCard(tweet: parseState.result!.tweet),
            },
            if (parseState.recent.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(AppStrings.recentParsed, style: Theme.of(context).textTheme.titleSmall),
              ),
              for (final tweet in parseState.recent)
                RecentParseTile(
                  tweet: tweet,
                  onTap: () => _openQualitySheet(
                    ResolveResult(tweet: tweet, parserVersion: 'recent'),
                    qualityMode,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _openQualitySheet(ResolveResult result, String qualityMode) {
    showQualitySheet(
      context,
      tweet: result.tweet,
      // 首选清晰度偏好（§3.2）：'720p' 省流 → 降序列表中首个 720p 档默认
      // 高亮（找不到 720p 档回落最高码率档）
      initialVariantIndex: _preferredVariantIndex(result.tweet.variants, qualityMode),
      onStartDownload: (variant, _) =>
          _startDownload(variant, result.tweet.tweetId, result.tweet),
      // 多视频推文：Chip 切换 → 按视频序号重新解析（TweetParser.resolve videoIndex）
      onSwitchVideo: result.tweet.videoCount > 1
          ? (videoIndex) => ref
              .read(tweetParserProvider.future)
              .then((parser) => parser.resolve(
                    result.tweet.tweetId,
                    videoIndex: videoIndex,
                  ))
          : null,
    );
  }

  /// 偏好档位索引：降序变体中首个 qualityLabel 含 '720p' 的位置；
  /// 偏好为 highest（默认）或找不到时回落 0（最高码率档）。
  int _preferredVariantIndex(List<VideoVariant> variants, String qualityMode) {
    if (qualityMode != kQualityMode720p) return 0;
    final sorted = List<VideoVariant>.of(variants)
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    for (var i = 0; i < sorted.length; i++) {
      if (sorted[i].qualityLabel.contains('720p')) return i;
    }
    return 0;
  }
}
