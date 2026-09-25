/// 下载引擎：FIFO 队列 + ParallelGate 信号量 + Range 断点续传 + 退避重试
/// + 403/410 重解析刷新直链 + 429 全队列冷却 + 3s 滑窗速率/ETA 节流广播。
///
/// 契约依据 DESIGN §4.3：
/// - 并发：[ParallelGate] permits=2（设置可调 1-3，规避限速）；
/// - 流式内存：dio `ResponseType.stream` + 64KB 缓冲循环写 `RandomAccessFile`，
///   任意大文件内存占用恒定；
/// - 断点续传：`Range: bytes={bytesDone}-`，三态处理
///   （206 追加 / 200 截断重写 / 中断保留 .part 退避后续传），
///   content-length 校验总量，每 64KB flush；
/// - 重试：指数退避 800ms×2^n+抖动，3 次后 failed(retryable=true)；
/// - 403/410：自动回炉重解析刷新直链一次（复用 tweetId，仅刷新 URL
///   不丢进度），仍失败才 failed；404 → failed(permanent)；
/// - 429：全队列 30s 冷却（暂停所有 running/queued，30s 后自动恢复）；
/// - 进度遥测：3s 滑窗 speedBps；ETA=剩余字节/平滑速率；500ms 节流广播。
///
/// 时钟注入：[NowFn]/[DelayFn] 可替换（测试用假时钟跑退避与冷却）。
/// 本文件不 import 任何平台插件与用户文案（文案由上层映射 app_strings）。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import 'download_task.dart';
import 'gallery_saver.dart';

/// 时钟注入：当前时间。
typedef NowFn = DateTime Function();

/// 时钟注入：等待指定时长（测试可替换为即时推进假时钟）。
typedef DelayFn = Future<void> Function(Duration duration);

/// 403/410 时的重解析回调：按 tweetId + bitrate 刷新直链。
/// 返回 null / 抛异常 = 刷新失败（任务转 failed(urlExpired)）。
typedef UrlRefresher = Future<String?> Function(String tweetId, int bitrate);

/// 指数退避策略：800ms × 2^n + 抖动（默认抖动上限为基数的 0.5 倍），
/// 3 次后放弃。语义与 DESIGN §4.3 / core/backoff.dart 完全一致；
/// 引擎侧自带该策略类以保证并行开发期编译稳定（见交付报告
/// contractDeviations），集成时可将 [BackoffPolicy.delayFor] 的实现
/// 委托给 core/backoff.dart（一处改动）。
class BackoffPolicy {
  BackoffPolicy({
    this.baseDelay = const Duration(milliseconds: 800),
    this.maxRetries = 3,
    this.maxDelay = const Duration(seconds: 30),
    // 私有命名参数（Dart 3.12+）：调用方仍以公共名 jitterFraction: 传参。
    this._jitterFraction = 0.5,
    Random? random,
  })  : _random = random ?? Random();

  final Duration baseDelay;
  final int maxRetries;
  final Duration maxDelay;
  final double _jitterFraction;
  final Random _random;

  /// 第 [retryIndex] 次（0 起）重试前的等待时长。
  Duration delayFor(int retryIndex) {
    final baseMs = baseDelay.inMilliseconds;
    final shift = retryIndex < 0 ? 0 : (retryIndex > 16 ? 16 : retryIndex);
    final expMs = baseMs * (1 << shift);
    final jitterMs =
        (_random.nextDouble() * baseMs * _jitterFraction).round();
    var totalMs = expMs + jitterMs;
    final capMs = maxDelay.inMilliseconds;
    if (totalMs > capMs) totalMs = capMs;
    if (totalMs < 0) totalMs = 0;
    return Duration(milliseconds: totalMs);
  }
}

/// 3 秒滑动窗口速率估计（DESIGN §4.3 进度遥测）。
class SpeedWindow {
  SpeedWindow({this.window = const Duration(seconds: 3)});

  final Duration window;
  final List<MapEntry<DateTime, int>> _samples = <MapEntry<DateTime, int>>[];

  /// 记录一次累计字节数采样；同时驱逐窗口外旧样本。
  void add(int cumulativeBytes, DateTime at) {
    _samples.add(MapEntry(at, cumulativeBytes));
    final cutoff = at.subtract(window);
    // 保留一个边界锚点（length > 2 才驱逐），保证窗口跨度可计算。
    while (_samples.length > 2 && _samples.first.key.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }

  void reset() => _samples.clear();

  int get sampleCount => _samples.length;

  /// 窗口内平滑速率（Bps）；样本不足 / 时间跨度为 0 / 无增量时为 0。
  int get speedBps {
    if (_samples.length < 2) return 0;
    final first = _samples.first;
    final last = _samples.last;
    final dtUs = last.key.difference(first.key).inMicroseconds;
    if (dtUs <= 0) return 0;
    final dBytes = last.value - first.value;
    if (dBytes <= 0) return 0;
    return (dBytes * 1000000.0 / dtUs).round();
  }
}

/// FIFO 信号量。permits 钳制在 1-3（DESIGN：设置可调 1-3）。
class ParallelGate {
  ParallelGate(int permits) {
    _permits = _clampPermits(permits);
  }

  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  int _permits = 2;
  int _active = 0;

  int get permits => _permits;

  /// 运行中占用的许可数（测试断言并发上限用）。
  int get active => _active;

  int get availablePermits => _permits - _active;

  set permits(int value) {
    _permits = _clampPermits(value);
    _pump();
  }

  Future<void> acquire() {
    if (_active < _permits) {
      _active++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.addLast(completer);
    return completer.future;
  }

  void release() {
    if (_active > 0) _active--;
    _pump();
  }

  void _pump() {
    while (_active < _permits && _waiters.isNotEmpty) {
      _active++;
      _waiters.removeFirst().complete();
    }
  }

  static int _clampPermits(int v) => v < 1 ? 1 : (v > 3 ? 3 : v);
}

/// 引擎离散通知（冷却开始/结束）。UI 文案由上层映射 app_strings
/// （DESIGN §7："触发限速，队列稍后自动继续"），引擎不内嵌用户可见文案。
enum EngineNoticeKind { rateLimitCooldownStarted, rateLimitCooldownEnded }

class EngineNotice {
  const EngineNotice._(this.kind, this.cooldownUntil);

  final EngineNoticeKind kind;

  /// 仅冷却开始事件非空：冷却截止时刻。
  final DateTime? cooldownUntil;

  factory EngineNotice.rateLimitCooldownStarted(DateTime until) =>
      EngineNotice._(EngineNoticeKind.rateLimitCooldownStarted, until);

  factory EngineNotice.rateLimitCooldownEnded() =>
      const EngineNotice._(EngineNoticeKind.rateLimitCooldownEnded, null);
}

/// 引擎 ↔ 持久层接缝（DESIGN §4.3：内存队列，重启经 drift 恢复）。
/// 由 data 层 HistoryRepository 适配实现（upsert 由实现方自行防抖/异步落盘）。
abstract class DownloadStore {
  void upsert(DownloadTask task);
}

/// 下载引擎。单例由 Riverpod 暴露（DESIGN §4.3）；本类自身保持无全局状态。
class DownloadEngine {
  DownloadEngine({
    Dio? dio,
    // 私有命名参数（Dart 3.12+）：调用方仍以公共名
    // downloadDir: / gallerySaver: / urlRefresher: / store: 传参。
    this._downloadDir,
    this._gallerySaver,
    int concurrency = 2,
    this.cooldownDuration = const Duration(seconds: 30),
    this.progressThrottle = const Duration(milliseconds: 500),
    this.speedWindowDuration = const Duration(seconds: 3),
    this.chunkFlushBytes = 64 * 1024,
    BackoffPolicy? backoff,
    this._urlRefresher,
    this._store,
    this.albumName = 'ClipVault',
    NowFn? now,
    DelayFn? delay,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
            )),
        _gate = ParallelGate(concurrency),
        _backoff = backoff ?? BackoffPolicy(),
        _now = now ?? DateTime.now,
        _delay = delay ?? Future<void>.delayed;

  final Dio _dio;
  final Directory? _downloadDir;
  final GallerySaver? _gallerySaver;
  final ParallelGate _gate;
  final BackoffPolicy _backoff;
  final UrlRefresher? _urlRefresher;
  final DownloadStore? _store;
  final NowFn _now;
  final DelayFn _delay;

  /// 429 全队列冷却时长（默认 30s，DESIGN §4.3 / §1.4-P3）。
  final Duration cooldownDuration;

  /// 进度广播节流间隔（默认 500ms，DESIGN §4.3）。
  final Duration progressThrottle;

  /// 速率滑窗长度（默认 3s，DESIGN §4.3）。
  final Duration speedWindowDuration;

  /// 每累计写入多少字节 flush 一次（默认 64KB，DESIGN §4.3）。
  final int chunkFlushBytes;

  /// 相册名（DESIGN §8.4：ClipVault，中性名规避商标风险）。
  final String albumName;

  final Map<String, DownloadTask> _tasks = <String, DownloadTask>{};
  final Set<String> _runningIds = <String>{};
  final Map<String, _RunState> _subs = <String, _RunState>{};

  final StreamController<DownloadTask> _taskEvents =
      StreamController<DownloadTask>.broadcast();
  final StreamController<EngineNotice> _noticeCtrl =
      StreamController<EngineNotice>.broadcast();

  bool _cooling = false;
  DateTime? _cooldownUntil;
  int _cooldownGen = 0;
  bool _disposed = false;

  /// 任务快照流（状态变更即时发；进度按 [progressThrottle] 节流）。
  /// 广播流：订阅前发生的事件不回放，UI 侧应与持久层 Stream 合并（DESIGN §9-1）。
  Stream<DownloadTask> get taskEvents => _taskEvents.stream;

  /// 引擎通知流（429 冷却开始/结束等离散事件）。
  Stream<EngineNotice> get notices => _noticeCtrl.stream;

  /// 当前全部任务快照（入队顺序）。
  List<DownloadTask> get tasks => List<DownloadTask>.unmodifiable(_tasks.values);

  DownloadTask? task(String id) => _tasks[id];

  /// 并发上限（1-3，DESIGN §4.3；超界钳制）。
  int get concurrency => _gate.permits;

  set concurrency(int value) {
    _gate.permits = value;
    _pump();
  }

  /// 是否处于 429 全队列冷却中。
  bool get cooling => _cooling;

  /// 当前冷却截止时刻；未冷却为 null。
  DateTime? get cooldownUntil => _cooldownUntil;

  Directory? get downloadDir => _downloadDir;

  // --------------------------------------------------------------------
  // 队列操作
  // --------------------------------------------------------------------

  /// 新任务入队（必须处于 queued 状态；id 不得重复）。
  ///
  /// 业务键去重：同 (tweetId, bitrate) 存在未终结（queued/running/paused）
  /// 任务时抛 [DuplicateActiveTaskException]——.part 路径由
  /// `{tweetId}_{bitrate}` 确定性生成，重复入队会使两个任务并发追加写
  /// 同一断点文件，字节流交错损坏且转正竞态。终态（completed/failed/
  /// canceled）不占用业务键，同键可重新下载。
  DownloadTask enqueue(DownloadTask task) {
    if (_tasks.containsKey(task.id)) {
      throw ArgumentError('任务已存在: ${task.id}');
    }
    if (task.status != DownloadStatus.queued) {
      throw ArgumentError('新任务必须处于 queued 状态，当前 ${task.status.name}');
    }
    for (final existing in _tasks.values) {
      if (!existing.isSettled &&
          existing.tweetId == task.tweetId &&
          existing.bitrate == task.bitrate) {
        throw DuplicateActiveTaskException(
          tweetId: task.tweetId,
          bitrate: task.bitrate,
          existingTaskId: existing.id,
        );
      }
    }
    _tasks[task.id] = task;
    _store?.upsert(task);
    _taskEvents.add(task);
    _pump();
    return task;
  }

  /// 启动恢复（DESIGN §4.5）：持久层加载的全部未完成记录重新入队
  ///（仓库层不按 .part 存在性过滤）。
  ///
  /// 由应用装配层（main/HistoryRepository）在启动时调用：持久层加载未完成
  /// 记录后交给本方法。恢复语义：
  /// - .part 仍存在 → 以文件实际长度恢复 bytesDone（断点续传）；
  /// - .part 丢失/partPath 为 null → bytesDone 归零重新下载；
  /// - 终态记录仅登记（供历史页查询），不入队；
  /// - 恢复路径绕过运行时状态机守卫（崩溃残留的 running/paused 一律归队）。
  Future<void> restoreFrom(Iterable<DownloadTask> unfinished) async {
    for (final saved in unfinished) {
      if (_tasks.containsKey(saved.id)) continue;
      if (saved.isSettled) {
        _tasks[saved.id] = saved;
        continue;
      }
      var bytesDone = saved.bytesDone;
      final pp = saved.partPath;
      if (pp != null) {
        final part = File(pp);
        bytesDone = await part.exists() ? await part.length() : 0;
      }
      final restored = saved.copyWith(
        status: DownloadStatus.queued,
        bytesDone: bytesDone,
        autoRetries: 0,
        urlRefreshed: false,
        pausedForCooldown: false,
        speedBps: 0,
        failureKind: null,
        errorMessage: null,
      );
      _tasks[restored.id] = restored;
      _store?.upsert(restored);
      _taskEvents.add(restored);
    }
    _pump();
  }

  /// 用户暂停（幂等）：queued 直接置 paused；running 中断请求保留 .part。
  void pause(String id) {
    final task = _tasks[id];
    if (task == null) return;
    switch (task.status) {
      case DownloadStatus.queued:
        _apply(id, (t) => t.withStatus(DownloadStatus.paused));
      case DownloadStatus.running:
        final st = _subs[id];
        if (st != null) {
          st.pauseRequested = true;
          st.cancelToken.cancel('pause');
        }
      case DownloadStatus.paused:
        // 冷却暂停期间用户显式暂停：转为用户暂停语义（清除冷却标记，
        // 冷却结束不再自动复活；冷却恢复只对无用户信号的任务生效）。
        if (task.pausedForCooldown) {
          _apply(id, (t) => t.copyWith(pausedForCooldown: false));
        }
        break; // 幂等 no-op
      case DownloadStatus.completed:
      case DownloadStatus.failed:
      case DownloadStatus.canceled:
        break; // 幂等 no-op
    }
  }

  /// 恢复（paused → queued → 重新调度；从 .part 断点续传）。
  void resume(String id) {
    final task = _tasks[id];
    if (task == null || task.status != DownloadStatus.paused) return;
    _apply(id, (t) => t
        .withStatus(DownloadStatus.queued)
        .copyWith(pausedForCooldown: false));
    _pump();
  }

  /// 取消（幂等）：queued/paused 直接终态；running 中断请求保留 .part。
  void cancel(String id) {
    final task = _tasks[id];
    if (task == null) return;
    switch (task.status) {
      case DownloadStatus.queued:
      case DownloadStatus.paused:
        _apply(id, (t) => t.withStatus(DownloadStatus.canceled));
      case DownloadStatus.running:
        final st = _subs[id];
        if (st != null) {
          st.cancelRequested = true;
          st.cancelToken.cancel('cancel');
        }
      case DownloadStatus.completed:
      case DownloadStatus.failed:
      case DownloadStatus.canceled:
        break;
    }
  }

  /// 一键重试（failed/canceled → queued）：重置退避计数与 URL 刷新标记，
  /// 使 403/410 任务再次获得一次自动重解析机会（DESIGN §4.3）。
  void retry(String id) {
    final task = _tasks[id];
    if (task == null) return;
    if (task.status != DownloadStatus.failed &&
        task.status != DownloadStatus.canceled) {
      return;
    }
    _apply(id, (t) => t
        .withStatus(DownloadStatus.queued)
        .copyWith(
          autoRetries: 0,
          urlRefreshed: false,
          pausedForCooldown: false,
          failureKind: null,
          errorMessage: null,
          speedBps: 0,
        ));
    _pump();
  }

  /// 历史页"重新保存至相册"入口（albumSavedAt 为空时，DESIGN §4.4）。
  Future<bool> resaveToGallery(String id) async {
    final task = _tasks[id];
    if (task == null || task.filePath == null) return false;
    if (task.status != DownloadStatus.completed) return false;
    return _saveToGallery(id);
  }

  /// 关停引擎：中断全部活动请求，关闭流与 dio。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final st in _subs.values) {
      st.cancelRequested = true;
      st.cancelToken.cancel('dispose');
    }
    _dio.close(); // Dio.close 返回 void（非 Future），无需 await。
    await _taskEvents.close();
    await _noticeCtrl.close();
  }

  // --------------------------------------------------------------------
  // 调度
  // --------------------------------------------------------------------

  void _pump() {
    if (_cooling || _disposed) return;
    while (!_cooling && _gate.availablePermits > 0) {
      DownloadTask? next;
      for (final t in _tasks.values) {
        if (t.status == DownloadStatus.queued && !_runningIds.contains(t.id)) {
          next = t;
          break;
        }
      }
      if (next == null) break;
      // async 函数体在首个 await 前同步执行：_runningIds 同步登记，
      // 不会重复拉起同一任务。
      _runTask(next.id);
    }
  }

  Future<void> _runTask(String id) async {
    _runningIds.add(id);
    try {
      await _gate.acquire();
      if (_tasks[id]?.status != DownloadStatus.queued) {
        // 等待期间被暂停/取消/冷却：直接让出许可。
        return;
      }
      final st = _RunState();
      _subs[id] = st;
      _apply(id, (t) => t.withStatus(DownloadStatus.running));
      await _attemptLoop(id);
    } finally {
      _runningIds.remove(id);
      _subs.remove(id);
      _gate.release();
      if (!_disposed) _pump();
    }
  }

  Future<void> _attemptLoop(String id) async {
    while (true) {
      final task = _tasks[id];
      final st = _subs[id];
      if (task == null || st == null) return;
      try {
        await _performDownload(id, st);
        return; // 正常完成（内部已置 completed 并转正文件）
      } on _PauseSignal {
        _apply(id, (t) => t.withStatus(DownloadStatus.paused));
        return;
      } on _CancelSignal {
        _apply(id, (t) => t.withStatus(DownloadStatus.canceled));
        return;
      } on _CooldownSignal {
        _applyCooldownPause(id);
        return;
      } on _PermanentFailure catch (e) {
        _apply(id, (t) => t.copyWith(
              status: DownloadStatus.failed,
              failureKind: DownloadFailureKind.permanent,
              errorMessage: e.message,
            ));
        return;
      } on _RetryExhausted catch (e) {
        _apply(id, (t) => t.copyWith(
              status: DownloadStatus.failed,
              failureKind: DownloadFailureKind.retryable,
              errorMessage: e.message,
            ));
        return;
      } on _ExpiredUrl {
        // 403/410：自动回炉重解析刷新直链一次，仅换 URL 不丢进度。
        final refreshed = await _tryRefreshUrl(task, st);
        if (!refreshed) {
          _apply(id, (t) => t.copyWith(
                status: DownloadStatus.failed,
                failureKind: DownloadFailureKind.urlExpired,
                errorMessage: 'url-refresh-failed',
              ));
          return;
        }
        continue; // 不计入退避次数
      } catch (e) {
        // 控制信号引发的底层异常（abort 以非 DioException 形态冒出）：
        // 不走退避，按信号语义收敛状态。
        if (st.cancelRequested) {
          _apply(id, (t) => t.withStatus(DownloadStatus.canceled));
          return;
        }
        if (st.pauseRequested) {
          _apply(id, (t) => t.withStatus(DownloadStatus.paused));
          return;
        }
        if (st.cooldownRequested) {
          _applyCooldownPause(id);
          return;
        }
        // 网络类/未知异常：指数退避，3 次后 failed(retryable=true)。
        final current = _tasks[id]!;
        if (current.autoRetries >= _backoff.maxRetries) {
          _apply(id, (t) => t.copyWith(
                status: DownloadStatus.failed,
                failureKind: DownloadFailureKind.retryable,
                errorMessage: 'network: $e',
              ));
          return;
        }
        final retryCount = current.autoRetries + 1;
        final wait = _backoff.delayFor(retryCount - 1);
        _apply(id, (t) => t.copyWith(autoRetries: retryCount));
        await _delay(wait);
        // 退避期间可能被暂停/取消。
        final stAfter = _subs[id];
        final tAfter = _tasks[id];
        if (stAfter == null || tAfter == null) return;
        if (stAfter.cancelRequested) {
          _apply(id, (t) => t.withStatus(DownloadStatus.canceled));
          return;
        }
        if (stAfter.pauseRequested) {
          _apply(id, (t) => t.withStatus(DownloadStatus.paused));
          return;
        }
        if (tAfter.status != DownloadStatus.running) return;
      }
    }
  }

  // --------------------------------------------------------------------
  // 单次尝试：Range 请求 → 三态 → 流式写盘 → 校验 → 转正
  // --------------------------------------------------------------------

  Future<void> _performDownload(String id, _RunState st) async {
    var task = _tasks[id]!;
    final dir = await _ensureDir();

    // 1. 分配 .part 路径并以文件实际长度对齐断点（不丢进度）。
    final partPath =
        task.partPath ?? _joinPath(dir.path, '${task.tweetId}_${task.bitrate}.part');
    final partFile = File(partPath);
    var bytesDone = 0;
    if (await partFile.exists()) {
      bytesDone = await partFile.length();
    }
    if (task.partPath != partPath || task.bytesDone != bytesDone) {
      _apply(id, (t) => t.copyWith(partPath: partPath, bytesDone: bytesDone));
      task = _tasks[id]!;
    }

    // 2. Range 请求（ResponseType.stream，DESIGN §4.3 流式内存）。
    final Response<ResponseBody> response;
    try {
      response = await _dio.get<ResponseBody>(
        task.variantUrl,
        cancelToken: st.cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (int? code) => code != null && code > 0,
          headers: <String, String>{
            if (bytesDone > 0) 'Range': 'bytes=$bytesDone-',
            'Accept': '*/*',
          },
        ),
      );
    } on DioException catch (e) {
      final signal = _classifyCancel(e, st);
      if (signal != null) throw signal;
      rethrow;
    }

    final code = response.statusCode ?? 0;
    final body = response.data!;

    // 3. 错误状态分流。
    if (code == 429) {
      await _drain(body);
      // 排水窗口内用户可能已登记 cancel/pause：用户意图优先于冷却信号
      //（cancel 高于一切，pause 次之），该任务按用户信号收敛终态/暂停态，
      // 不被冷却暂停、也不在冷却结束后自动复活（与流写循环 _signalOf 的
      // 优先级语义一致）。
      if (st.cancelRequested) throw _CancelSignal();
      if (st.pauseRequested) throw _PauseSignal();
      final current = _tasks[id]!;
      if (current.autoRetries >= _backoff.maxRetries) {
        throw _RetryExhausted('rate-limited');
      }
      _apply(id, (t) => t.copyWith(autoRetries: t.autoRetries + 1));
      _startCooldown();
      throw _CooldownSignal();
    }
    if (code == 403 || code == 410) {
      // 直链签名过期：交由 _attemptLoop 刷新 URL（DESIGN §4.3，403 不归"锁推"）。
      await _drain(body);
      throw _ExpiredUrl();
    }
    if (code == 404) {
      await _drain(body);
      throw _PermanentFailure('http-404');
    }
    if (code >= 500) {
      await _drain(body);
      throw _TransientHttp('http-$code');
    }
    if (code >= 400) {
      await _drain(body);
      throw _PermanentFailure('http-$code');
    }

    // 4. 206/200 三态处理（DESIGN §4.3）。
    const http206 = 206;
    var append = false; // true=从 bytesDone 追加；false=截断从零重写。
    int? totalBytes;
    if (code == http206) {
      append = true;
      final cr = response.headers.value('content-range') ?? '';
      final m = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+)').firstMatch(cr);
      if (m != null) {
        final start = int.parse(m.group(1)!);
        totalBytes = int.parse(m.group(3)!);
        if (start != bytesDone) {
          if (start == 0) {
            // 服务器从 0 重发：等价范围被忽略，走重写路径。
            append = false;
            bytesDone = 0;
          } else {
            throw _TransientHttp('range-mismatch: got $start, want $bytesDone');
          }
        }
      } else {
        final cl = response.headers.value('content-length');
        totalBytes = cl != null ? bytesDone + int.parse(cl) : null;
      }
    } else {
      // 200（范围被忽略）→ 截断 .part 从零重写。
      append = false;
      bytesDone = 0;
      final cl = response.headers.value('content-length');
      totalBytes = cl != null ? int.parse(cl) : null;
    }

    // 5. 64KB 缓冲循环写 RandomAccessFile（DESIGN §4.3 流式内存）。
    final raf = await partFile.open(mode: append ? FileMode.append : FileMode.write);
    final window = SpeedWindow(window: speedWindowDuration);
    var lastEmit = _now();
    var sinceFlush = 0;
    var wrote = bytesDone;
    try {
      await for (final chunk in body.stream) {
        // 控制信号优先（token.cancel 同时触发底层流终止，此处兜底）。
        if (st.cancelRequested || st.pauseRequested || st.cooldownRequested) {
          _emitProgress(id, wrote, totalBytes, window);
          throw _signalOf(st);
        }
        await raf.writeFrom(chunk);
        wrote += chunk.length;
        sinceFlush += chunk.length;
        if (sinceFlush >= chunkFlushBytes) {
          await raf.flush(); // 每 64KB flush（DESIGN §4.3）。
          sinceFlush -= chunkFlushBytes;
        }
        window.add(wrote, _now());
        final nowT = _now();
        if (nowT.difference(lastEmit) >= progressThrottle) {
          lastEmit = nowT;
          _emitProgress(id, wrote, totalBytes, window);
        }
      }
      await raf.flush();
    } on Object catch (e) {
      // 中断（pause/cancel/cooldown 的 token.abort）可能以任意异常形态从
      // 底层流冒出：先检查控制信号，避免误判为网络错误进入退避。
      if (st.cancelRequested || st.pauseRequested || st.cooldownRequested) {
        _emitProgress(id, wrote, totalBytes, window);
        throw _signalOf(st);
      }
      if (e is DioException) {
        final signal = _classifyCancel(e, st);
        if (signal != null) {
          _emitProgress(id, wrote, totalBytes, window);
          throw signal;
        }
      }
      rethrow;
    } finally {
      await raf.close();
    }

    // 6. content-length 校验总量：短读 = 连接中断 → 保留 .part 退避续传。
    if (totalBytes != null && wrote != totalBytes) {
      throw _TransientHttp('incomplete: $wrote/$totalBytes');
    }

    // 7. 转正：.part → {tweetId}_{bitrate}.mp4（DESIGN §5.5 存储布局）。
    final finalPath = _joinPath(
        dir.path, '${task.tweetId}_${task.bitrate}.${task.contentType}');
    final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    await partFile.rename(finalPath);

    _apply(id, (t) => t.copyWith(
          status: DownloadStatus.completed,
          bytesDone: totalBytes ?? wrote,
          bytesTotal: totalBytes ?? t.bytesTotal,
          filePath: finalPath,
          speedBps: 0,
          etaSec: 0,
        ));

    // 8. 入册（不阻塞完成态；权限被拒降级沙盒，albumSavedAt 置空）。
    await _saveToGallery(id);
  }

  Future<bool> _saveToGallery(String id) async {
    final saver = _gallerySaver;
    if (saver == null) return false;
    final task = _tasks[id];
    if (task == null || task.status != DownloadStatus.completed) return false;
    if (task.filePath == null) return false;
    final result =
        await saver.saveVideo(path: task.filePath!, album: albumName);
    if (_tasks[id] == null) return result.isSaved;
    _apply(id, (t) => t.copyWith(
          albumSavedAt: result.isSaved ? result.savedAt : null,
        ));
    return result.isSaved;
  }

  /// 403/410 重解析回调（每任务一次；手动重试重置标记再次获得机会）。
  Future<bool> _tryRefreshUrl(DownloadTask task, _RunState st) async {
    final refresher = _urlRefresher;
    if (task.urlRefreshed || refresher == null) return false;
    _apply(task.id, (t) => t.copyWith(urlRefreshed: true));
    try {
      final fresh = await refresher(task.tweetId, task.bitrate);
      if (fresh == null || fresh.isEmpty) return false;
      _apply(task.id, (t) => t.copyWith(variantUrl: fresh));
      return true;
    } catch (_) {
      return false;
    }
  }

  // --------------------------------------------------------------------
  // 429 全队列冷却（DESIGN §4.3：暂停所有 running/queued，30s 自动恢复）
  // --------------------------------------------------------------------

  /// 冷却中断的 running 任务落 paused(cooldown)；若冷却已结束（竞态直达）
  /// 则进一步回归 queued 并重新调度。
  ///
  /// 用户已登记的意图优先于冷却暂停（cancel 高于一切，pause 次之）：
  /// 该任务按用户信号收敛（取消/用户暂停），不带冷却标记，也就不参与
  /// 冷却结束的自动复活。
  void _applyCooldownPause(String id) {
    final st = _subs[id];
    if (st != null) {
      if (st.cancelRequested) {
        _apply(id, (t) => t.withStatus(DownloadStatus.canceled));
        return;
      }
      if (st.pauseRequested) {
        _apply(id, (t) => t.withStatus(DownloadStatus.paused));
        return;
      }
    }
    _apply(id, (t) => t
        .withStatus(DownloadStatus.paused)
        .copyWith(pausedForCooldown: true));
    if (!_cooling) {
      _apply(id, (t) => t
          .withStatus(DownloadStatus.queued)
          .copyWith(pausedForCooldown: false));
      _pump();
    }
  }

  void _startCooldown() {
    final until = _now().add(cooldownDuration);
    if (_cooling) {
      // 已在冷却中：延长截止时刻并以新一代结束任务重新计时（新触发的
      // 429 已计入 autoRetries，不会形成热循环）。
      final current = _cooldownUntil;
      if (current == null || until.isAfter(current)) {
        _cooldownUntil = until;
        _scheduleCooldownEnd();
      }
      return;
    }
    _cooling = true;
    _cooldownUntil = until;
    if (!_noticeCtrl.isClosed) {
      _noticeCtrl.add(EngineNotice.rateLimitCooldownStarted(until));
    }
    // 暂停所有 running：置冷却标记并中断请求（.part 保留，进度不丢）。
    for (final st in _subs.values) {
      st.cooldownRequested = true;
      st.cancelToken.cancel('cooldown');
    }
    // 暂停所有 queued（DESIGN：暂停所有 running/queued 任务）。
    for (final t in _tasks.values.toList()) {
      if (t.status == DownloadStatus.queued) {
        _apply(t.id, (x) => x
            .withStatus(DownloadStatus.paused)
            .copyWith(pausedForCooldown: true));
      }
    }
    _scheduleCooldownEnd();
  }

  void _scheduleCooldownEnd() {
    final gen = ++_cooldownGen;
    unawaited(() async {
      await _delay(cooldownDuration);
      if (gen != _cooldownGen || !_cooling || _disposed) return;
      // 等待被中断的 running 任务完成 paused 转移（有限微任务轮）。
      for (var i = 0; i < 20; i++) {
        if (!_subs.values.any((s) => s.cooldownRequested)) break;
        await Future<void>.delayed(Duration.zero);
      }
      _cooling = false;
      _cooldownUntil = null;
      if (!_noticeCtrl.isClosed) {
        _noticeCtrl.add(EngineNotice.rateLimitCooldownEnded());
      }
      for (final t in _tasks.values.toList()) {
        if (t.status == DownloadStatus.paused && t.pausedForCooldown) {
          _apply(t.id, (x) => x
              .withStatus(DownloadStatus.queued)
              .copyWith(pausedForCooldown: false));
        }
      }
      _pump();
    }());
  }

  // --------------------------------------------------------------------
  // 内部工具
  // --------------------------------------------------------------------

  Future<Directory> _ensureDir() async {
    final dir = _downloadDir ??
        Directory(
            '${Directory.systemTemp.path}${Platform.pathSeparator}xdown_downloads');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String _joinPath(String a, String b) =>
      a.endsWith(Platform.pathSeparator) ? '$a$b' : '$a${Platform.pathSeparator}$b';

  /// 统一状态演进出口：变更后同步持久层并广播。
  void _apply(String id, DownloadTask Function(DownloadTask t) transform) {
    final current = _tasks[id];
    if (current == null) return;
    final next = transform(current);
    if (identical(next, current)) return;
    _tasks[id] = next;
    _store?.upsert(next);
    if (!_taskEvents.isClosed) {
      _taskEvents.add(next);
    }
  }

  void _emitProgress(String id, int bytesDone, int? total, SpeedWindow window) {
    _apply(id, (t) {
      final speed = window.speedBps;
      final int? eta = total != null && speed > 0
          ? ((total - bytesDone) / speed).ceil()
          : null;
      return t.copyWith(
        bytesDone: bytesDone,
        bytesTotal: total ?? t.bytesTotal,
        speedBps: speed,
        etaSec: eta,
      );
    });
  }

  Exception _signalOf(_RunState st) {
    if (st.cancelRequested) return _CancelSignal();
    if (st.pauseRequested) return _PauseSignal();
    return _CooldownSignal();
  }

  Exception? _classifyCancel(DioException e, _RunState st) {
    if (e.type != DioExceptionType.cancel) return null;
    return _signalOf(st);
  }

  Future<void> _drain(ResponseBody body) async {
    try {
      await body.stream.drain<void>();
    } catch (_) {
      // 忽略错误体的排水异常。
    }
  }
}

/// 单任务运行态（控制信号 + 取消令牌）。
class _RunState {
  final CancelToken cancelToken = CancelToken();
  bool pauseRequested = false;
  bool cancelRequested = false;
  bool cooldownRequested = false;
}

// ---- 引擎内部信号/失败分类（不进入公共契约） ----

class _PauseSignal implements Exception {}

class _CancelSignal implements Exception {}

class _CooldownSignal implements Exception {}

class _ExpiredUrl implements Exception {}

class _PermanentFailure implements Exception {
  _PermanentFailure(this.message);
  final String message;
}

class _RetryExhausted implements Exception {
  _RetryExhausted(this.message);
  final String message;
}

class _TransientHttp implements Exception {
  _TransientHttp(this.message);
  final String message;
}
