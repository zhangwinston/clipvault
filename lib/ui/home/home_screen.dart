/// 首页（DESIGN §7.1-1）：
/// 复合操作条（输入框内嵌清空 × 与主 CTA——空输入时 CTA 是
/// 「粘贴并解析」，有输入时收敛为「解析」）；
/// 剪贴板 resume 命中 → 顶部内联横幅（同链接去重，§4.1-2）；
/// 解析中骨架卡片 + 耗时计时；解析成功 → QualitySheet → 开始下载 → toast；
/// 最近解析卡片（内存态）+ 七类错误视图。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/clipboard/clipboard_watcher.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/core/backoff.dart';
import 'package:clipvault/core/error.dart';
import 'package:clipvault/core/url_extract.dart';
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/parse/parser_provider.dart';
import 'package:clipvault/settings/proxy_auto_provider.dart';
import 'package:clipvault/settings/settings_controller.dart';
import 'package:clipvault/sharing/share_receiver.dart';
import 'package:clipvault/ui/common/brand.dart';
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
    this.retryAttempt = 0,
  });

  final HomePhase phase;
  final ParseError? error;
  final ResolveResult? result;
  final List<TweetMeta> recent;

  /// 当前网络退避重试轮次（1 起；0 = 首次尝试）。
  /// 供骨架卡展示「正在重试（2/3）…」，让退避等待可解释。
  final int retryAttempt;

  HomeParseState copyWith({
    HomePhase? phase,
    ParseError? error,
    ResolveResult? result,
    List<TweetMeta>? recent,
    int? retryAttempt,
    bool clearError = false,
    bool clearResult = false,
  }) {
    return HomeParseState(
      phase: phase ?? this.phase,
      error: clearError ? null : (error ?? this.error),
      result: clearResult ? null : (result ?? this.result),
      recent: recent ?? this.recent,
      retryAttempt: retryAttempt ?? this.retryAttempt,
    );
  }
}

enum HomePhase { idle, parsing, error, resolved }

/// 首页解析控制器（Notifier）：URL 校验 → TweetParser.resolve → 状态落位
class HomeParseController extends Notifier<HomeParseState> {
  /// 解析代际序号：每次 parse/cancel 递增；旧的在途请求完成时因代际过期
  /// 而丢弃结果——修复「等待中粘贴新链接再解析，旧请求后完成弹出与
  /// 输入框不符的 Sheet，点开始下载就下错视频」的竞态（P0-1）。
  int _generation = 0;

  @override
  HomeParseState build() => const HomeParseState();

  /// 当前解析器（生产按端点配置仓库构建；测试 override tweetParserProvider）
  Future<TweetParser> get _parser => ref.read(tweetParserProvider.future);

  /// 取消进行中的解析（骨架卡「取消解析」按钮）：
  /// 代际 +1 使在途请求结果作废，回到 idle。
  void cancel() {
    _generation++;
    if (state.phase == HomePhase.parsing) {
      state = state.copyWith(
        phase: HomePhase.idle,
        retryAttempt: 0,
        clearError: true,
        clearResult: true,
      );
    }
  }

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
    _generation++;
    final generation = _generation;
    state = state.copyWith(
      phase: HomePhase.parsing,
      retryAttempt: 0,
      clearError: true,
      clearResult: true,
    );
    // 自动代理预检（§6.9 双向自动调节）：Wi-Fi 下直连可用自动关 / 直连
    // 不可用预探测启用。骨架卡已上屏吸收等待；协调器内预算封顶（≤3s），
    // TTL 缓存后近零成本。
    await ref.read(proxyAutoCoordinatorProvider).preflight();
    if (generation != _generation) return; // 预检等待期间被取消/替换：丢弃
    ParseError? lastError;
    try {
      final result = await _resolveWithRetry(tweetId, generation);
      if (generation != _generation) return; // 已被新解析/取消取代：丢弃
      // 同推文去重后置顶（P2-3：避免重复条目占满 5 个名额）
      final recent = List<TweetMeta>.of(state.recent)
        ..removeWhere((t) => t.tweetId == result.tweet.tweetId)
        ..insert(0, result.tweet);
      if (recent.length > 5) recent.removeRange(5, recent.length);
      state = state.copyWith(
        phase: HomePhase.resolved,
        result: result,
        retryAttempt: 0,
        recent: recent.toList(growable: false),
      );
      return;
    } on ParseError catch (e) {
      lastError = e;
    } catch (_) {
      // 兜底归 E02（_resolveWithRetry 内已归一，此处防御）
      lastError = NetworkTimeout();
    }
    if (generation != _generation) return; // 已被新解析/取消取代：丢弃
    state = state.copyWith(
      phase: HomePhase.error,
      error: lastError,
      retryAttempt: 0,
      clearResult: true,
    );
  }

  /// 解析编排（PRD §5 / DESIGN §6.5/§6.7）：
  /// - E02（NetworkTimeout）：指数退避自动重试 3 次（800ms×2^n+抖动），
  ///   重试期间 phase 保持 parsing（骨架卡片持续），且把轮次透出到
  ///   state.retryAttempt 供骨架卡展示「正在重试（n/3）…」；
  /// - E03/E04/E06 等非网络类不自动重试；
  /// - E07（EndpointDrift）：经端点配置仓库 onEndpointDrift() 刷新，
  ///   刷新到新配置则 invalidate 重建解析器后重试一次（免发版自愈链路）。
  Future<ResolveResult> _resolveWithRetry(String tweetId, int generation) async {
    final backoff = ref.read(parseRetryBackoffProvider);
    var networkAttempts = 0;
    while (true) {
      if (networkAttempts > 0) {
        // 把重试轮次透出给骨架卡（代际守卫：被取消/替换时不写状态）
        if (generation == _generation) {
          state = state.copyWith(retryAttempt: networkAttempts);
        }
        // 退避等待（fakeAsync/测试伪时钟可确定性断言间隔）
        await backoff.wait(networkAttempts - 1);
        if (generation != _generation) {
          // 等待期间被取消/替换：以错误形态退出，外层按代际丢弃。
          throw NetworkTimeout();
        }
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
            // 直连失败兜底（§6.9）：探测在退避窗口内后台完成，第 2/3 次
            // 重试经 findProxy 实时读缓存即走新代理
            unawaited(ref
                .read(proxyAutoCoordinatorProvider)
                .onDirectFailure(source: 'parse'));
            networkAttempts++;
            break; // 退避后重试（骨架持续）
          }
          rethrow; // 非网络类 / 退避耗尽：透出
        } catch (_) {
          // 非 ParseError 的网络/IO 异常统一归 E02（§6.6）后再走退避判定
          if (backoff.hasRetryLeft(networkAttempts)) {
            unawaited(ref
                .read(proxyAutoCoordinatorProvider)
                .onDirectFailure(source: 'parse'));
            networkAttempts++;
            break;
          }
          throw NetworkTimeout();
        }
      }
    }
  }

  void reset() {
    state = state.copyWith(
      phase: HomePhase.idle,
      retryAttempt: 0,
      clearError: true,
      clearResult: true,
    );
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

  /// 剪贴板横幅一次性解释是否已展示过（持久化，§8.2 前置解释）。
  bool _clipboardExplained = true;
  // 在 initState 中取一次实例，避免 dispose 阶段访问 ref
  late final ClipboardWatcher _clipboardWatcher;

  @override
  void initState() {
    super.initState();
    // 输入变化驱动 CTA 动态形态（空=「粘贴并解析」/ 有内容=「解析」）
    _input.addListener(_onInputChanged);
    // 挂载剪贴板生命周期观察者（resume 时机读取，§8.2）
    _clipboardWatcher = ref.read(clipboardWatcherProvider.notifier);
    WidgetsBinding.instance.addObserver(_clipboardWatcher);
    // 一次性解释标记加载（默认 true = 不再展示）
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _clipboardExplained =
            prefs.getBool(_kClipboardExplainedPref) ?? false);
      }
    });
    // P1：系统分享文本 → 自动填充并解析（§7 导航流）
    final share = ref.read(shareReceiverProvider);
    _shareSub = share.sharedText().listen(_onSharedText);
    share.initialText().then((value) {
      if (value != null && value.isNotEmpty) _onSharedText(value);
    });
  }

  void _onInputChanged() {
    // 重建以切换 CTA 图标/文案与清空按钮的显隐
    if (mounted) setState(() {});
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
    _input
      ..removeListener(_onInputChanged)
      ..dispose();
    super.dispose();
  }

  /// 剪贴板横幅首次出现时的一次性解释标记（P2-8：把「我的·权限说明」
  /// 的解释前置到用户被系统粘贴提示困扰的现场）。
  static const String _kClipboardExplainedPref = 'clipboard.explained';

  Future<void> _markClipboardExplained() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kClipboardExplainedPref, true);
    if (mounted) setState(() => _clipboardExplained = true);
  }

  Future<void> _parseInput() async {
    await ref.read(homeParseControllerProvider.notifier).parse(_input.text);
  }

  /// 合并主 CTA（视觉评审主题 G：此前「解析/粘贴」双按钮动线冗余——
  /// 剪贴板横幅已实现一键粘贴+解析，双按钮与之功能重叠且语义近邻）：
  /// 输入有内容直接解析；为空则读剪贴板；两者皆空给出可感知反馈
  /// （此前空输入点「解析」静默无反应）。
  Future<void> _pasteAndParse() async {
    var text = _input.text.trim();
    if (text.isEmpty) {
      final clip = await ref.read(clipboardReaderProvider).readText();
      text = (clip ?? '').trim();
      if (text.isNotEmpty && mounted) {
        setState(() => _input.text = text);
      }
    }
    if (text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.homeEmptyInput)),
      );
      return;
    }
    await ref.read(homeParseControllerProvider.notifier).parse(text);
  }

  // 注：独立「粘贴」按钮已随主题 G 的 CTA 合并移除
  //（_pasteAndParse 内置剪贴板回退）。

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
      // 品牌 AppBar（主题 A：logo + 双色字标，替代纯文本标题）
      appBar: AppBar(title: const BrandTitle()),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            // 剪贴板内联横幅（点击立即解析；§1.3-#4 横幅而非浮窗）：
            // 副文案带推文 ID 尾号（用户可确认目标），首次出现附一次性解释。
            // 视觉语言与 InfoBanner 统一（圆角 12 + 16/8 外边距 + accent 竖条）。
            if (pendingClipboard != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      onTap: () {
                        ref.read(clipboardWatcherProvider.notifier).consume();
                        if (!_clipboardExplained) _markClipboardExplained();
                        _input.text = pendingClipboard;
                        _parseInput();
                      },
                      child: Semantics(
                        // 核心入口出现时对读屏用户可达（P1-12）
                        liveRegion: true,
                        child: Row(
                          children: [
                            Container(
                              width: 4,
                              color: scheme.onSecondaryContainer,
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                child: Row(
                                  children: [
                                    Icon(Icons.content_paste_search,
                                        size: 20,
                                        color: scheme.onSecondaryContainer),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            AppStrings.clipboardBanner,
                                            style: TextStyle(
                                              color: scheme.onSecondaryContainer,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          if (_tweetIdSummary(pendingClipboard)
                                              case final summary?)
                                            Text(
                                              summary,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: scheme.onSecondaryContainer,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: AppStrings.homeClear,
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () {
                                        ref
                                            .read(clipboardWatcherProvider.notifier)
                                            .consume();
                                        if (!_clipboardExplained) {
                                          _markClipboardExplained();
                                        }
                                      },
                                      icon: Icon(Icons.close,
                                          size: 20,
                                          color: scheme.onSecondaryContainer),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (!_clipboardExplained)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Text(
                    AppStrings.clipboardBannerExplain,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
            // 复合操作条（2026-10-04：输入框与主 CTA 上下堆叠 → 单容器融合，
            // 输入与解析本是同一行为闭环，不再分占两行首屏高度）：
            // - 空输入：CTA 为「粘贴并解析」（读剪贴板回退，_pasteAndParse）；
            // - 有输入：CTA 收敛为「解析」，且露出清空按钮；
            // - 主题的全局 filled/描边输入样式在此整体关闭，改为容器自绘。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _pasteAndParse(),
                        decoration: const InputDecoration(
                          hintText: AppStrings.homeInputHint,
                          isDense: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    if (_input.text.isNotEmpty)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: AppStrings.homeClear,
                        onPressed: _input.clear,
                        icon: const Icon(Icons.clear, size: 20),
                      ),
                    const SizedBox(width: 4),
                    FilledButton.icon(
                      // 稳定键：widget 测试以 byKey 触达（文案随输入态切换）
                      key: const Key('homeParseCta'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _pasteAndParse,
                      icon: Icon(
                        _input.text.trim().isEmpty
                            ? Icons.content_paste
                            : Icons.bolt,
                        size: 18,
                      ),
                      label: Text(
                        _input.text.trim().isEmpty
                            ? AppStrings.homePasteAndParse
                            : AppStrings.homeParse,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            switch (parseState.phase) {
              // 空态三步引导（P1-3）：无结果且无最近解析时展示，
              // 首次解析成功后自然消失（recent 非空）。
              HomePhase.idle =>
                (parseState.result == null && parseState.recent.isEmpty)
                    ? const _HomeGuideCard()
                    : const SizedBox.shrink(),
              HomePhase.parsing => ParseSkeleton(
                  retryAttempt: parseState.retryAttempt,
                  maxRetries: ref.watch(parseRetryBackoffProvider).maxRetries,
                  onCancel: () =>
                      ref.read(homeParseControllerProvider.notifier).cancel(),
                ),
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

  /// 横幅副文案：推文 ID 尾 6 位摘要（如「推文 …43991」），
  /// 让用户确认将解析的是哪条链接；无法提取时无副文案。
  String? _tweetIdSummary(String? clipboardText) {
    final id = extractTweetId(clipboardText ?? '');
    if (id == null || id.length < 4) return null;
    return '${AppStrings.clipboardBannerTweetPrefix} …${id.substring(id.length - 6)}';
  }

  void _openQualitySheet(ResolveResult result, String qualityMode) {
    showQualitySheet(
      context,
      tweet: result.tweet,
      // 首选清晰度偏好（§3.2）：'720p' 省流 → 降序列表中首个 720p 档默认
      // 高亮（找不到 720p 档回落最高码率档）
      initialVariantIndex: _preferredVariantIndex(result.tweet.variants, qualityMode),
      // 多视频切换后按新视频档位重新匹配偏好（P1-5：不再沿用旧索引错档）
      preferredVariantIndex: (variants) =>
          _preferredVariantIndex(variants, qualityMode),
      onStartDownload: (variant, _) =>
          _startDownload(variant, result.tweet.tweetId, result.tweet),
      // 多视频推文：Chip 切换 → 按视频序号重新解析（TweetParser.resolve videoIndex）
      onSwitchVideo: result.tweet.videoCount > 1
          ? (videoIndex) async {
              // 旁路解析入口同样先过代理预检（§6.9），与主解析入口一致
              await ref.read(proxyAutoCoordinatorProvider).preflight();
              final parser = await ref.read(tweetParserProvider.future);
              return parser.resolve(
                result.tweet.tweetId,
                videoIndex: videoIndex,
              );
            }
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

/// 首页空态三步引导卡（P1-3 → 2026-10-04 重做）：
/// 顶部极简「链接 → 媒体」插画（单帧 16:9 卡 + 播放圆钮 + 链接角标，
/// 柔光打底，替代此前半透明多帧层叠的「廉价感」占位）；
/// 三步编号圆标（正文文案不再重复 ①②③ 序号），
/// 分享提示收底改半透明胶囊通知条样式。
/// 无结果且无最近解析时展示；首次解析成功后由条件自然移除。
class _HomeGuideCard extends StatelessWidget {
  const _HomeGuideCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _GuideHero(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.homeGuideTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 14),
                _step(context, 1, AppStrings.homeGuideStep1),
                const SizedBox(height: 10),
                _step(context, 2, AppStrings.homeGuideStep2),
                const SizedBox(height: 10),
                _step(context, 3, AppStrings.homeGuideStep3),
                const SizedBox(height: 16),
                // 分享提示：半透明主色胶囊条（2026-10-04：分隔线 + 裸灰字
                // → 通知条样式，视觉上从「步骤」中独立出来）
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.share_outlined,
                          size: 16, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          AppStrings.homeGuideShareHint,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(BuildContext context, int number, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            '$number',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    );
  }
}

/// 极简空态插画（2026-10-04）：单一 16:9 媒体帧 + 播放圆钮 + 链接角标，
/// primaryContainer 柔光打底——语义直白「粘链接 → 得视频」，
/// 替代此前三张半透明渐变帧错位层叠的抽象占位（零资产依赖，代码自绘）。
class _GuideHero extends StatelessWidget {
  const _GuideHero();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            // 柔光：primaryContainer 径向渐隐，建立视觉重心不发闷
            Container(
              width: 224,
              height: 224,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    scheme.primaryContainer.withValues(alpha: 0.55),
                    scheme.primaryContainer.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
            // 媒体帧：16:9 白底圆角卡 + 描边（与全局卡片语言一致）
            Container(
              width: 160,
              height: 90,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.outlineVariant),
              ),
              alignment: Alignment.center,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child:
                    Icon(Icons.play_arrow, size: 24, color: scheme.primary),
              ),
            ),
            // 链接角标：帧右上角探出的 primary 圆钮，点明「链接」入口语义
            Positioned(
              top: -8,
              right: -8,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  border: Border.fromBorderSide(
                    BorderSide(color: scheme.surfaceContainerLow, width: 2.5),
                  ),
                ),
                child: Icon(Icons.link, size: 16, color: scheme.onPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
