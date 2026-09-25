/// 推文链接提取与归一化（DESIGN §4.1）——纯函数，零网络请求、零平台依赖。
///
/// 单一正则覆盖全部输入形态：
///  - 域名：`x.com` / `twitter.com`，子域 `www.` / `m.` / `mobile.` / `web.`；
///  - 路径：`/{user}/status(es)/{id}`、`/i/web/status/{id}`（无用户名形态）；
///  - 后缀：`/video/N`、`?s=20&t=…` 查询串（匹配在 ID 数字串处自然截断）；
///  - 输入可为纯 URL，也可为分享文案中夹杂链接（含中英文空格混排）——
///    首个命中即返回；
///  - Tweet ID 双重校验（DESIGN §4.1）：15~20 位数字 + int64 范围。
///
/// t.co 短链解析为 P1 项（HEAD 跟随 Location），P0 阶段 t.co 链接不命中。
library;

/// 单一提取正则。
///
/// 说明：DESIGN §4.1 给出的正则示意 `…/(?:i/web/)?[^/]+/status(?:es)?/(\d+)`
/// 在字面上无法匹配其同时要求容忍的 `web.twitter.com/i/web/status/{id}`
///（`i/web/` 前缀与强制用户名段 `[^/]+/` 互斥），故此处将用户名段放宽为
/// 可选 `(?:[^/]+/)?`，并把子域集扩为含 `web`——覆盖原正则的全部命中集
/// 的同时满足 prose 要求的全部形态（详见 contractDeviations 申报）。
final RegExp _tweetUrlPattern = RegExp(
  r'https?://(?:(?:www|m|mobile|web)\.)?(?:x|twitter)\.com/'
  r'(?:i/web/)?(?:[^/]+/)?status(?:es)?/(\d+)',
  caseSensitive: false,
);

/// int64 上限（Tweet ID 双重校验之二）。
final BigInt _int64Max = BigInt.parse('9223372036854775807');

/// 纯 ASCII 数字且 15~20 位（DESIGN §4.1 双重校验之一）。
///
/// Dart `\d` 仅匹配 [0-9]，天然拒绝全角数字、科学计数法与正负号。
/// 必须先行字符集校验：[BigInt.tryParse] 与 int.parse 同样容忍首尾空白，
/// 如 `'1790637656616943991 '`（长度 20 恰在界内）会被当作合法数字放行，
/// 违背「15~20 位数字」语义。
final RegExp _tweetIdDigits = RegExp(r'^\d{15,20}$');

/// Tweet ID 合法性：15~20 位数字且 ≤ 2^63−1（DESIGN §4.1）。
bool isValidTweetId(String id) {
  if (!_tweetIdDigits.hasMatch(id)) {
    return false;
  }
  final BigInt? value = BigInt.tryParse(id);
  return value != null && value <= _int64Max;
}

/// 提取结果：Tweet ID + 归一化 URL（去子域/去查询串/去视频后缀的规范形）。
class ExtractedTweetUrl {
  const ExtractedTweetUrl({required this.tweetId, required this.normalizedUrl});

  /// 15~20 位数字串（保持完整十进制，不丢精度——勿转 int 存储）。
  final String tweetId;

  /// 归一化 URL：`https://x.com/i/web/status/{tweetId}`。
  /// 剪贴板横幅「同一链接去重」以本字段或 tweetId 为键。
  final String normalizedUrl;

  @override
  bool operator ==(Object other) =>
      other is ExtractedTweetUrl &&
      other.tweetId == tweetId &&
      other.normalizedUrl == normalizedUrl;

  @override
  int get hashCode => Object.hash(tweetId, normalizedUrl);

  @override
  String toString() => 'ExtractedTweetUrl($tweetId)';
}

/// 从任意文本提取推文链接；未命中或 Tweet ID 校验不过返回 null
///（调用方归入 E01 UrlInvalid，零网络请求）。
ExtractedTweetUrl? extractTweetUrl(String input) {
  if (input.isEmpty) {
    return null;
  }
  final RegExpMatch? match = _tweetUrlPattern.firstMatch(input);
  if (match == null) {
    return null;
  }
  final String id = match.group(1)!;
  if (!isValidTweetId(id)) {
    return null;
  }
  return ExtractedTweetUrl(
    tweetId: id,
    normalizedUrl: 'https://x.com/i/web/status/$id',
  );
}

/// 轻量入口：仅提取 Tweet ID（Home 输入框 / 剪贴板横幅 / 分享接收共用）。
String? extractTweetId(String input) => extractTweetUrl(input)?.tweetId;
