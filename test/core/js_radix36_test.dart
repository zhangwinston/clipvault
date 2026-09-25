import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/core/js_number_radix36.dart';
import 'package:clipvault/core/token.dart';

/// jsNumberToStringRadix 对照测试（DESIGN §11.1）。
///
/// 三重验证之前两重：
///  1. V8 参考向量：期望值全部取自 Node 24.11（V8 13.6）原生
///     `Number.prototype.toString(36)` 实测输出，硬编码断言；
///  2. 语料穷举：`test/resources/token_corpus.csv`
///     （tools/token_corpus.mjs 以 V8 原生 toString(36) 生成，参考实现，
///     非 Dart 同公式自我印证）逐行对照 radix36 与 token 两列。
void main() {
  group('特殊值（JS 语义）', () {
    test('NaN / 零 / 无穷', () {
      expect(jsNumberToStringRadix(double.nan, 36), 'NaN');
      expect(jsNumberToStringRadix(0, 36), '0');
      expect(jsNumberToStringRadix(-0.0, 36), '0'); // JS: (-0).toString(36) === '0'
      expect(jsNumberToStringRadix(double.infinity, 36), 'Infinity');
      expect(jsNumberToStringRadix(double.negativeInfinity, 36), '-Infinity');
    });

    test('参数校验：radix 越界抛 RangeError，radix 10 抛 UnsupportedError', () {
      expect(() => jsNumberToStringRadix(1, 1), throwsRangeError);
      expect(() => jsNumberToStringRadix(1, 37), throwsRangeError);
      expect(() => jsNumberToStringRadix(1, 10), throwsUnsupportedError);
    });

    test('负数 = 前缀 + 绝对值表示', () {
      expect(jsNumberToStringRadix(-1.5, 36), '-1.i');
      expect(jsNumberToStringRadix(-1, 36), '-1');
    });
  });

  group('V8 参考向量（Node 24.11 实测输出，硬编码）', () {
    final List<(double, String)> vectors = <(double, String)>[
      // 常规与精确小数
      (0.5, '0.i'),
      (1.5, '1.i'),
      (2.5, '2.i'),
      (100.5, '2s.i'),
      (1.0 / 3.0, '0.c'), // 乘 36 后舍入到精确 12 → 单位小数自然终止
      (1.0000000000000002, '1.0000000001'),
      // 无理样例：逐位乘 36 进位 + delta 阈值终止（10~12 位有效数字）
      (0.1, '0.3lllllllllm'),
      (0.2, '0.77777777778'),
      (0.3, '0.asssssssssp'),
      (0.7, '0.p777777777'),
      (1234.5678, 'ya.kfv9yqdpm'),
      (6283.185, '4uj.6nrcyk5s'),
      (123456789.125, '21i3v9.4i'),
      (1000000.5, 'lfls.i'),
      (math.pi, '3.53i5ab8p5f'),
      (math.e, '2.puw5nggjf8'),
      // 进位回溯：小数段末位 round-to-even 进链
      (35.99999999999999, 'z.zzzzzzzzz'),
      (2.9999999999999996, '2.zzzzzzzzzz'),
      (0.9999999999999999, '0.zzzzzzzzzza'),
      // 整数
      (1, '1'),
      (35, 'z'),
      (36, '10'),
      (1296, '100'),
      // 2^52/2^53 边界（IEEE754 双精度整数边界）
      (4503599627370495.0, '18ce53un18f'), // 2^52 - 1
      (4503599627370496.0, '18ce53un18g'), // 2^52
      (4503599627370497.0, '18ce53un18h'), // 2^52 + 1
      (9007199254740991.0, '2gosa7pa2gv'), // 2^53 - 1
      (9007199254740992.0, '2gosa7pa2gw'), // 2^53
      (9007199254740994.0, '2gosa7pa2gy'), // 2^53 + 2
      (1152921504619192654.0, '8rc4kbe35e00'), // 2^60 + 12345678
      // 大整数：≥2^53 后垫 0 路径（V8 固有行为：低位精度退化）
      (1e21, '5v1j4f4ds7c000'),
      (324259173170675712.0, '2gosa7pa2gw0'), // 2^53 × 36
      (324259173170675713.0, '2gosa7pa2gw0'), // 2^53 × 36 + 1（同串，V8 一致）
      // 极端量级（'0' × n 为算术化构造，零的个数与 Node 实测串逐一核对）
      (1e-300, '0.${'0' * 192}2box4rhe6qp'), // len 205
      (5e-324, '0.${'0' * 207}3'), // len 210：最小正 double
      (2.2250738585072014e-308, '0.${'0' * 197}34lmua2oev'), // len 209：最小规格化 = 2^-1022
      (1.7976931348623157e308, '1a1e4vngaiqo${'0' * 187}'), // len 199：最大 double
    ];

    test('逐向量与 V8 原生输出一致', () {
      for (final (v, expected) in vectors) {
        final String actual = jsNumberToStringRadix(v, 36);
        expect(actual, expected,
            reason: 'value=$v 期望 $expected，实际 $actual');
      }
    });

    test('token 已知向量的中间值（DESIGN §6.2 实测）', () {
      const String id = '1790637656616943991';
      final double v = (double.parse(id) / 1e15) * math.pi;
      expect(jsNumberToStringRadix(v, 36), '4c9.gcitu1vq');
    });
  });

  group('其他 radix 抽查（算法为通用移植）', () {
    test('radix 2 / 16', () {
      expect(jsNumberToStringRadix(0.5, 2), '0.1');
      expect(jsNumberToStringRadix(10, 2), '1010');
      expect(jsNumberToStringRadix(255, 16), 'ff');
      expect(jsNumberToStringRadix(35.5, 36), 'z.i');
    });
  });

  group('语料穷举对照（token_corpus.csv，V8 参考实现生成）', () {
    final File csv = File('test/resources/token_corpus.csv');

    test('逐行断言 radix36 与 token 两列（10 万级）', () {
      if (!csv.existsSync()) {
        // S1 并行生成中：按 DESIGN §11.1 约定路径与 CSV 格式编写，
        // 集中验证阶段由 tools/token_corpus.mjs 产出后必跑。
        markTestSkipped('test/resources/token_corpus.csv 尚未生成'
            '（运行 node tools/token_corpus.mjs）');
        return;
      }
      final List<String> lines = csv.readAsLinesSync();
      expect(lines.first, 'tweetId,radix36,token',
          reason: 'CSV 表头须为 tweetId,radix36,token');
      int checked = 0;
      for (final String line in lines.skip(1)) {
        if (line.isEmpty) {
          continue;
        }
        final List<String> cols = line.split(',');
        expect(cols.length, 3, reason: 'CSV 行须为 3 列: $line');
        final TokenParts parts = computeToken(cols[0]);
        expect(parts.radix36, cols[1],
            reason: 'id=${cols[0]} radix36 不一致');
        expect(parts.token, cols[2],
            reason: 'id=${cols[0]} token 不一致');
        checked++;
      }
      expect(checked, greaterThan(100000),
          reason: '语料须为 10 万级（DESIGN §11.1 穷举要求）');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
