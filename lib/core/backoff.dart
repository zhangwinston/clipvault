/// 指数退避（DESIGN §4.3 / §6.5：800ms×2^n + 抖动，3 次）。
///
/// 解析层与下载引擎共用：序列为 800ms → 1.6s → 3.2s（各加抖动），
/// 3 次后透出失败态（解析语境）或 failed(retryable=true) 一键重试（下载语境）。
/// 抖动可注入（[JitterFactory]）以保证测试确定性；默认抖动为
/// [0, 25%) × 当前档位延迟 的均匀分布。
library;

import 'dart:math' as math;

/// 抖动生成器：入参为当前档位的基础延迟（未加抖动），返回抖动量。
/// 测试注入确定性实现以断言精确序列。
typedef JitterFactory = Duration Function(Duration delay);

/// 指数退避计算器（纯计算，不持有定时器；等待由调用方 `Future.delayed`
/// 或本类 [wait] 完成，便于 fakeAsync 伪时钟断言）。
class ExponentialBackoff {
  /// 构造；[jitterFactory] 为 null 时使用默认随机抖动。
  ExponentialBackoff({
    this.baseDelay = const Duration(milliseconds: 800),
    this.maxRetries = 3,
    this.jitterFactor = 0.25,
    JitterFactory? jitterFactory,
  })  : assert(baseDelay > Duration.zero, 'baseDelay 必须为正'),
        assert(maxRetries > 0, 'maxRetries 必须 ≥ 1'),
        assert(jitterFactor >= 0, 'jitterFactor 不得为负'),
        _customJitter = jitterFactory;

  /// 基础延迟（DESIGN §4.3：800ms）。
  final Duration baseDelay;

  /// 最大自动重试次数（DESIGN §4.3：3 次）。
  final int maxRetries;

  /// 默认抖动幅度系数（相对当前档位延迟的均匀上界比例）。
  final double jitterFactor;

  final JitterFactory? _customJitter;

  static final math.Random _random = math.Random();

  /// 第 [retry] 次重试（0 起，`0 ≤ retry < maxRetries`）前的退避延迟：
  /// `baseDelay × 2^retry + jitter`。
  Duration delayForRetry(int retry) {
    RangeError.checkValueInInterval(retry, 0, maxRetries - 1, 'retry');
    final Duration scaled = baseDelay * (1 << retry);
    final Duration jitter =
        _customJitter?.call(scaled) ?? _defaultJitter(scaled);
    return scaled + jitter;
  }

  Duration _defaultJitter(Duration delay) {
    if (jitterFactor <= 0) {
      return Duration.zero;
    }
    return Duration(
      microseconds:
          (delay.inMicroseconds * jitterFactor * _random.nextDouble()).round(),
    );
  }

  /// 已重试 [retriesDone] 次后是否仍有自动重试余量。
  bool hasRetryLeft(int retriesDone) => retriesDone < maxRetries;

  /// 按第 [retry] 次的退避延迟等待（fakeAsync 测试中配合 elapse 断言时序）。
  Future<void> wait(int retry) => Future<void>.delayed(delayForRetry(retry));
}
