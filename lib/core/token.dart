/// X(Twitter) syndication token 计算（DESIGN §6.2 唯一权威实现）。
///
/// 与官方嵌入组件及 yt-dlp master `_generate_syndication_token` 逐字一致：
/// ```js
/// ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '')
/// ```
/// 已知向量：`1790637656616943991 → 4c9gcitu1vq`
/// （中间值 `4c9.gcitu1vq`，评委源码比对 + 独立复现双确认）。
///
/// Dart 侧三步（DESIGN §6.2）：
///  1. [double.parse] = JS `Number(id)`：十进制字符串按 IEEE754 正确舍入为
///     double（推文 ID 超 2^53 存在双精度舍入，位级一致）；
///  2. `(n / 1e15) * math.pi`：与 JS 逐位一致的 IEEE754 double 运算
///     （`1e15` 与 `math.pi` 均为精确同值 double 字面量）；
///  3. [jsNumberToStringRadix]（V8 位级一致的 36 进制）+ 剥离 `0` 与 `.`。
library;

import 'dart:math' as math;

import 'js_number_radix36.dart';

/// token 计算的两段产出：`radix36` 为 `toString(36)` 中间值（可能含 `.` 与 `0`），
/// `token` 为剥离后的最终值（可能为空串，如 id=0）。
/// 供语料对照测试（token_corpus.csv 的 radix36/token 两列）逐列断言。
typedef TokenParts = ({String radix36, String token});

/// JS `/(0+|\.)/g`：贪婪 '0' 连串或字面 '.'，全部替换为空。
final RegExp _stripPattern = RegExp(r'(0+|\.)');

/// 计算 [tweetId]（纯数字字符串，超 2^53 按 IEEE754 舍入）的 syndication token。
///
/// 输入须为合法十进制数字串（调用方 [url_extract] 已做 15~20 位 + int64 校验）；
/// 非法输入由 [double.parse] 抛出 [FormatException]。
TokenParts computeToken(String tweetId) {
  final double n = double.parse(tweetId); // == JS Number(id)
  final double v = (n / 1e15) * math.pi;
  final String radix36 = jsNumberToStringRadix(v, 36);
  return (radix36: radix36, token: radix36.replaceAll(_stripPattern, ''));
}

/// 便捷入口：只取最终 token（解析端点 `&token=` 参数值）。
String getToken(String tweetId) => computeToken(tweetId).token;
