/// 错误模型（DESIGN §5.2 / §6.6；契约源：contracts/error_codes.md）。
///
/// - [ParseError]：解析域七类，sealed + 穷举 switch，编译期强制全覆盖，
///   一物一视图（ui/common/error_views.dart）；UI 话术收口于 app_strings.dart。
/// - [DownloadError]：下载域三分类，供引擎内部区分重试语义；
///   HTTP 429 不属于单任务错误，而是触发全队列 30s 冷却（DESIGN §4.3）。
///
/// 红线（contracts/error_codes.md）：403 在解析语境归 [RateLimited]（风控），
/// 在下载语境归 [DownloadUrlExpired]（直链签名过期，自动重解析刷新），
/// 任何实现不得把 403 归入「锁推」提示。
library;

/// 解析域错误（七类，码值 E01~E07 与 contracts/error_codes.md 一致；
/// 亦即 drift 表 DownloadRecords.errorCode 列的取值域）。
sealed class ParseError implements Exception {
  const ParseError();

  /// 契约码值（E01~E07）。
  String get code;

  @override
  String toString() => 'ParseError($code)';
}

/// E01：链接格式 / 位数 / int64 校验不过——零网络请求。
final class UrlInvalid extends ParseError {
  const UrlInvalid([this.input]);

  /// 原始输入（诊断用，可空）。
  final String? input;

  @override
  String get code => 'E01';

  @override
  bool operator ==(Object other) =>
      other is UrlInvalid && other.input == input;

  @override
  int get hashCode => Object.hash('E01', input);
}

/// E02：网络层异常 / DNS / 6s 接收超时——退避 3 次自动重试后透出 + 一键重试。
final class NetworkTimeout extends ParseError {
  const NetworkTimeout({this.reason, this.timeout});

  /// 底层异常摘要（诊断用，可空）。
  final String? reason;

  /// 触发超时的时限（默认 6s，可随端点配置变化，可空）。
  final Duration? timeout;

  @override
  String get code => 'E02';

  @override
  bool operator ==(Object other) =>
      other is NetworkTimeout &&
      other.reason == reason &&
      other.timeout == timeout;

  @override
  int get hashCode => Object.hash('E02', reason, timeout);
}

/// E03：上游 429 / 403 风控（独立分类）——触发备源切换；
/// 下载语境另触发全队列 30s 冷却。403 不归「锁推」。
final class RateLimited extends ParseError {
  const RateLimited({this.statusCode});

  /// 上游状态码（429/403 等，可空）。
  final int? statusCode;

  @override
  String get code => 'E03';

  @override
  bool operator ==(Object other) =>
      other is RateLimited && other.statusCode == statusCode;

  @override
  int get hashCode => Object.hash('E03', statusCode);
}

/// E04：HTTP 404 / dogpage HTML（content-type text/html）/ 200 + 空 `{}`。
/// 锁推通常表现为 404/空{}，合并提示并附「非公开推文无法解析」补充文案。
final class TweetNotFound extends ParseError {
  const TweetNotFound();

  @override
  String get code => 'E04';

  @override
  bool operator ==(Object other) => other is TweetNotFound;

  @override
  int get hashCode => 'E04'.hashCode;
}

/// E05：200 合法 JSON 但 mediaDetails 无 type ∈ {video, animated_gif} 条目。
final class NotVideoTweet extends ParseError {
  const NotVideoTweet();

  @override
  String get code => 'E05';

  @override
  bool operator ==(Object other) => other is NotVideoTweet;

  @override
  int get hashCode => 'E05'.hashCode;
}

/// E06：possibly_sensitive == true 或媒体字段缺失受限启发式。
/// 硬性约束：不加载缩略图（NSFW 双保险之一）。
final class RestrictedContent extends ParseError {
  const RestrictedContent();

  @override
  String get code => 'E06';

  @override
  bool operator ==(Object other) => other is RestrictedContent;

  @override
  int get hashCode => 'E06'.hashCode;
}

/// E07：`__typename != 'Tweet'` 或关键字段结构性缺失（守卫）。
/// 触发端点配置刷新检查（DESIGN §6.7）+ 本地哨兵日志。
final class EndpointDrift extends ParseError {
  const EndpointDrift([this.detail]);

  /// 结构缺失细节（哨兵日志用，可空）。
  final String? detail;

  @override
  String get code => 'E07';

  @override
  bool operator ==(Object other) => other is EndpointDrift && other.detail == detail;

  @override
  int get hashCode => Object.hash('E07', detail);
}

/// 按契约码反序列化（drift 启动恢复 errorCode 列 → 错误对象）；
/// 未知码返回 null（前向兼容）。
ParseError? parseErrorFromCode(String code) {
  switch (code) {
    case 'E01':
      return const UrlInvalid();
    case 'E02':
      return const NetworkTimeout();
    case 'E03':
      return const RateLimited();
    case 'E04':
      return const TweetNotFound();
    case 'E05':
      return const NotVideoTweet();
    case 'E06':
      return const RestrictedContent();
    case 'E07':
      return const EndpointDrift();
    default:
      return null;
  }
}

/// 下载域错误（引擎内部三分类，DESIGN §5.2 / §4.3）。
sealed class DownloadError implements Exception {
  const DownloadError();

  /// 码值（retryable / permanent / urlExpired，与 contracts/error_codes.md 一致）。
  String get code;

  @override
  String toString() => 'DownloadError($code)';
}

/// 网络类错误：指数退避 800ms×2^n + 抖动，3 次后 failed(retryable=true)
/// 供一键重试。
final class DownloadRetryable extends DownloadError {
  const DownloadRetryable([this.reason]);

  /// 底层异常摘要（诊断用，可空）。
  final String? reason;

  @override
  String get code => 'retryable';

  @override
  bool operator ==(Object other) =>
      other is DownloadRetryable && other.reason == reason;

  @override
  int get hashCode => Object.hash('retryable', reason);
}

/// 不可恢复（如 404）：直接 failed(permanent)，不重试。
final class DownloadPermanent extends DownloadError {
  const DownloadPermanent(this.reason);

  /// 不可恢复原因（如 'HTTP 404'）。
  final String reason;

  @override
  String get code => 'permanent';

  @override
  bool operator ==(Object other) =>
      other is DownloadPermanent && other.reason == reason;

  @override
  int get hashCode => Object.hash('permanent', reason);
}

/// 直链签名过期（403/410，video.twimg.com 签名参数失效）：
/// 自动回炉重解析刷新直链一次（复用 tweetId，仅刷新 URL 不丢进度）再重试。
final class DownloadUrlExpired extends DownloadError {
  const DownloadUrlExpired();

  @override
  String get code => 'urlExpired';

  @override
  bool operator ==(Object other) => other is DownloadUrlExpired;

  @override
  int get hashCode => 'urlExpired'.hashCode;
}
