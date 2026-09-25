import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/core/backoff.dart';

/// 指数退避序列测试（DESIGN §11.1）：800ms×2^n+抖动序列、3 次上限、注入时钟断言。
Duration _zeroJitter(Duration _) => Duration.zero;

void main() {
  group('序列断言（注入零抖动 → 精确 800/1600/3200ms）', () {
    final ExponentialBackoff backoff =
        ExponentialBackoff(jitterFactory: _zeroJitter);

    test('delayForRetry 序列 800ms × 2^n', () {
      expect(backoff.delayForRetry(0), const Duration(milliseconds: 800));
      expect(backoff.delayForRetry(1), const Duration(milliseconds: 1600));
      expect(backoff.delayForRetry(2), const Duration(milliseconds: 3200));
    });

    test('序列展开与 3 次上限', () {
      final List<Duration> schedule = List<Duration>.generate(
          3, (int i) => backoff.delayForRetry(i));
      expect(schedule, const [
        Duration(milliseconds: 800),
        Duration(milliseconds: 1600),
        Duration(milliseconds: 3200),
      ]);
    });
  });

  group('注入抖动', () {
    test('固定抖动叠加到各档位', () {
      final ExponentialBackoff backoff = ExponentialBackoff(
        jitterFactory: (Duration d) => const Duration(milliseconds: 100),
      );
      expect(backoff.delayForRetry(0), const Duration(milliseconds: 900));
      expect(backoff.delayForRetry(1), const Duration(milliseconds: 1700));
      expect(backoff.delayForRetry(2), const Duration(milliseconds: 3300));
    });

    test('比例抖动按档位基数计算', () {
      final ExponentialBackoff backoff = ExponentialBackoff(
        jitterFactory: (Duration d) => Duration(microseconds: d.inMicroseconds ~/ 10),
      );
      expect(backoff.delayForRetry(0), const Duration(milliseconds: 880));
      expect(backoff.delayForRetry(1), const Duration(milliseconds: 1760));
    });
  });

  group('默认抖动范围（0 ≤ jitter < 25% × 档位）', () {
    final ExponentialBackoff backoff = ExponentialBackoff();

    test('各档位 1000 次采样均落在界内', () {
      for (int retry = 0; retry < 3; retry++) {
        final Duration base = const Duration(milliseconds: 800) * (1 << retry);
        // round(<0.25×base) 可达 base~/4，故上界取闭界
        final Duration ceil = base + base ~/ 4;
        for (int i = 0; i < 1000; i++) {
          final Duration d = backoff.delayForRetry(retry);
          expect(d >= base, isTrue,
              reason: 'retry=$retry 第$i 次 $d 低于基数 $base');
          expect(d <= ceil, isTrue,
              reason: 'retry=$retry 第$i 次 $d 超出抖动上界 $ceil');
        }
      }
    });
  });

  group('重试余量与参数校验', () {
    test('hasRetryLeft：3 次上限', () {
      final ExponentialBackoff backoff = ExponentialBackoff();
      expect(backoff.hasRetryLeft(0), isTrue);
      expect(backoff.hasRetryLeft(2), isTrue);
      expect(backoff.hasRetryLeft(3), isFalse);
      expect(backoff.hasRetryLeft(4), isFalse);
    });

    test('retry 越界抛 RangeError', () {
      final ExponentialBackoff backoff = ExponentialBackoff();
      expect(() => backoff.delayForRetry(-1), throwsRangeError);
      expect(() => backoff.delayForRetry(3), throwsRangeError);
    });

    test('自定义基数与次数（引擎并发/解析层复用同一实现）', () {
      final ExponentialBackoff fast = ExponentialBackoff(
        baseDelay: const Duration(milliseconds: 200),
        maxRetries: 2,
        jitterFactory: _zeroJitter,
      );
      expect(fast.delayForRetry(0), const Duration(milliseconds: 200));
      expect(fast.delayForRetry(1), const Duration(milliseconds: 400));
      expect(() => fast.delayForRetry(2), throwsRangeError);
      expect(fast.hasRetryLeft(1), isTrue);
      expect(fast.hasRetryLeft(2), isFalse);
    });
  });

  group('wait 时序（fakeAsync 伪时钟）', () {
    test('零抖动下 799ms 未完成、800ms 完成', () {
      final ExponentialBackoff backoff =
          ExponentialBackoff(jitterFactory: _zeroJitter);
      fakeAsync((FakeAsync async_) {
        bool done = false;
        backoff.wait(0).then((_) => done = true);
        async_.elapse(const Duration(milliseconds: 799));
        expect(done, isFalse);
        async_.elapse(const Duration(milliseconds: 1));
        expect(done, isTrue);
      });
    });

    test('第 2 次退避在 1600ms 处完成（注入时钟推进断言）', () {
      final ExponentialBackoff backoff =
          ExponentialBackoff(jitterFactory: _zeroJitter);
      fakeAsync((FakeAsync async_) {
        bool done = false;
        backoff.wait(1).then((_) => done = true);
        async_.elapse(const Duration(milliseconds: 1599));
        expect(done, isFalse);
        async_.elapse(const Duration(milliseconds: 1));
        expect(done, isTrue);
      });
    });
  });
}
