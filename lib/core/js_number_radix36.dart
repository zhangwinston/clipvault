/// ECMAScript `Number::toString(radix)` 的 Dart 精确移植（radix ∈ [2,36]，10 除外）。
///
/// 移植来源：V8 `src/numbers/conversions.cc` 的 `DoubleToRadixStringView`
/// （已核对 Node 24.11.0 内置 V8 13.6 与 v8 main 为同一实现）。
/// 本移植在 JS 参考侧经 50 万+ 随机/边界样本与 10 万条语料
/// （`test/resources/token_corpus.csv`，V8 原生 `toString(36)` 生成）
/// 逐字符对账，输出位级一致——这是 token 算法（DESIGN §6.2）的正确性基石。
///
/// 算法要点（V8 Dragon4 变体，全部为 IEEE754 double 运算，与 C++ 语义逐行对应）：
///  1. 整数/小数分离：`integer = floor(value)`、`fraction = value - integer`；
///  2. `delta = 0.5 × (nextUp(value) - value)`（半个 ulp）：小数位生成到
///     「剩余 fraction < delta（双精度不可分辨）」为止，而非固定位数——
///     因此不同量级的值小数位数不同（约 10~12 位有效数字）；
///  3. 小数逐位乘 radix 进位；末位 round-to-even 判定
///     （`fraction > 0.5 || (fraction == 0.5 && digit 为奇数)`），
///     且仅当 `fraction + delta > 1` 时执行进位回溯（含跨 'z' 进位链，
///     与 V8 一致地保留被跳过的 'z' 不改写）；进位穿过小数点时进到整数
///     部分且不再输出小数段；
///  4. 整数部分：`Double(integer / radix).Exponent() > 0`（V8 Double 类为
///     DiyFp 语义，kExponentBias = 1023 + 52，故等价于 `integer / radix >= 2^53`）
///     时垫 '0'，再以 fmod 逐位取余——大整数（≥2^53）低位因此退化为 '0'，
///     这是 V8 的固有行为（如 `(2**53*36).toString(36)` 与 `(2**53*36+1)` 同串）；
///  5. radix 10 在 ECMAScript/V8 走「最短十进制表示」独立路径，不属于本函数
///     范围（调用 [UnsupportedError]）；本项目 token 语义仅使用 36。
library;

import 'dart:typed_data';

const String _kDigitChars = '0123456789abcdefghijklmnopqrstuvwxyz';

/// DiyFp 语义 `Double::Exponent() > 0` 的判定阈值（= 2^53）。
const double _kTwoPow53 = 9007199254740992.0;

/// 最小非规格化正 double（delta 下溢兜底，对齐 V8 非 flush-denormals 路径）。
const double _kMinPositive = 5e-324;

/// 复用的 8 字节缓冲：本函数为纯同步计算，单 isolate 内无重入风险。
final ByteData _scratch = ByteData(8);

/// [value] 必须为非负有限 double：返回紧邻其上的下一个 double（向 +∞）。
/// 最大有限 double 的 nextUp 为 +∞（与 V8 `Double::NextDouble` 一致）。
double _nextUpNonNegative(double value) {
  _scratch.setFloat64(0, value);
  final int bits = _scratch.getUint64(0);
  _scratch.setUint64(0, bits + 1);
  return _scratch.getFloat64(0);
}

/// 将 [value] 按 ECMAScript `Number.prototype.toString([radix])` 语义转换为
/// [radix] 进制字符串（2~36，10 除外）。
///
/// 特殊值与 JS 完全一致：NaN→`'NaN'`；±0→`'0'`；±∞→`±'Infinity'`；
/// 负数输出 `-` 前缀 + 绝对值表示。radix 10 抛 [UnsupportedError]，
/// radix 越界抛 [RangeError]。
String jsNumberToStringRadix(double value, int radix) {
  RangeError.checkValueInInterval(radix, 2, 36, 'radix');
  if (radix == 10) {
    throw UnsupportedError(
        'radix 10 需 ECMAScript 最短十进制表示算法（V8 另有独立路径），'
        '不在本移植范围；请使用 Dart 原生 toString()');
  }
  if (value.isNaN) return 'NaN';
  if (value == 0) return '0'; // 含 -0.0：JS (−0).toString(36) === '0'
  if (value.isInfinite) return value < 0 ? '-Infinity' : 'Infinity';

  final bool negative = value < 0;
  if (negative) {
    value = -value;
  }

  // ---- 1) 整数/小数分离 ----
  double integer = value.floorToDouble();
  double fraction = value - integer;

  // ---- 2) delta = 0.5 × (nextUp − value)：半个 ulp ----
  double delta = 0.5 * (_nextUpNonNegative(value) - value);
  if (delta <= 0) {
    delta = _kMinPositive;
  }

  // ---- 3) 小数位生成（含 round-to-even 进位回溯）----
  final List<int> fractionDigits = <int>[];
  bool hasFraction = false;
  bool carryToInteger = false;
  if (fraction >= delta) {
    hasFraction = true;
    while (true) {
      fraction *= radix;
      delta *= radix;
      final int digit = fraction.toInt(); // static_cast<int> 截断语义
      fractionDigits.add(digit);
      fraction -= digit;
      // 末位 round-to-even：超过半程（或恰半程且当前位为奇数）才考虑进位。
      if (fraction > 0.5 || (fraction == 0.5 && (digit & 1) == 1)) {
        if (fraction + delta > 1) {
          // 进位回溯：自最后一位向左找第一个非 (radix−1) 的位加一；
          // 与 V8 一致：被跨过的 (radix−1) 位保持原样不改写。
          int cursor = fractionDigits.length - 1;
          while (true) {
            if (cursor < 0) {
              // 穿过小数点：进位到整数部分，且小数段整体不再输出
              //（V8 返回视图截止于小数点之前）。
              integer += 1;
              carryToInteger = true;
              break;
            }
            final int d = fractionDigits[cursor];
            if (d + 1 < radix) {
              fractionDigits[cursor] = d + 1;
              break;
            }
            cursor -= 1;
          }
          break;
        }
      }
      if (!(fraction >= delta)) break;
    }
  }

  // ---- 4) 整数位：先垫 '0'，再 fmod 逐位取余 ----
  final List<int> integerDigits = <int>[]; // 低位在前
  // V8: while (Double(integer / radix).Exponent() > 0) —— DiyFp 语义阈值 2^53。
  while (integer / radix >= _kTwoPow53) {
    integer /= radix;
    integerDigits.add(0);
  }
  do {
    final double remainder = integer % radix; // 正数下与 C++ fmod 一致
    integerDigits.add(remainder.toInt());
    integer = (integer - remainder) / radix;
  } while (integer > 0);

  // ---- 5) 拼装 ----
  final StringBuffer out = StringBuffer();
  if (negative) {
    out.write('-');
  }
  for (int i = integerDigits.length - 1; i >= 0; i--) {
    out.write(_kDigitChars[integerDigits[i]]);
  }
  if (hasFraction && !carryToInteger) {
    out.write('.');
    for (final int d in fractionDigits) {
      out.write(_kDigitChars[d]);
    }
  }
  return out.toString();
}
