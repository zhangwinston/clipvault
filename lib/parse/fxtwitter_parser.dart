/// FxTwitter 备源解析器（DESIGN §6.4，P1 降级备援，默认关闭）。
///
/// 防御性双形态：官方路径 GET https://api.fxtwitter.com/status/{id} 的
/// 响应结构存在两种已知形态（两评委核查结论矛盾 → 不得采信单一描述，§12-13）：
/// - 形态 A：tweet.media.videos[] 每项仅一条 `url` 直链（无码率字段）；
/// - 形态 B：videos[] 每项含 `formats[]` 多码率列表（url/format/bitrate）。
/// 两种形态都容忍；开工当日以 tools/fetch_fixtures.mjs 实测对账后锁定。
///
/// 备源同样实现 TweetParser 接口，经 endpoints 配置 fallback.enabled 开关（§6.4）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:clipvault/core/error.dart';

import 'endpoint_config.dart';
import 'models.dart';
import 'syndication_parser.dart' show mapDioExceptionToParseError;

/// 备源解析版本标识。
const String kFxTwitterParserVersion = 'fxtwitter-v1';

class FxTwitterParser implements TweetParser {
  FxTwitterParser({required this._dio, required this.config});

  final Dio _dio;

  /// 端点配置：urlTemplate 取 fallback.urlTemplate，开关取 fallback.enabled。
  final EndpointConfig config;

  /// 备源是否启用（编排层在 RateLimited/EndpointDrift 降级前检查，§6.5）。
  bool get isEnabled => config.fallback.enabled;

  @override
  Future<ResolveResult> resolve(String tweetId, {int videoIndex = 0}) async {
    final url = config.fallback.urlTemplate.replaceAll('{id}', tweetId);
    final FxRawResponse raw;
    try {
      raw = await _fetch(url);
    } on DioException catch (error) {
      throw mapDioExceptionToParseError(error);
    }
    return parseResponse(raw, tweetId: tweetId, videoIndex: videoIndex);
  }

  Future<FxRawResponse> _fetch(String url) async {
    final response = await _dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
        headers: const <String, String>{
          'Accept': 'application/json',
          'User-Agent': kDefaultBrowserUa,
        },
      ),
    );
    return FxRawResponse(
      statusCode: response.statusCode ?? 0,
      body: response.data ?? '',
    );
  }

  /// 纯分类+映射（无 IO）：备源夹具回放入口。
  ResolveResult parseResponse(
    FxRawResponse response, {
    required String tweetId,
    int videoIndex = 0,
  }) {
    switch (response.statusCode) {
      case 200:
        break;
      case 404:
        throw TweetNotFound();
      case 403:
      case 429:
        throw RateLimited();
      case >= 500:
        throw NetworkTimeout();
      default:
        throw EndpointDrift();
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body.trim());
    } on FormatException {
      throw EndpointDrift();
    }
    if (decoded is! Map<String, dynamic>) {
      throw EndpointDrift();
    }
    return parseBody(decoded, tweetId: tweetId, videoIndex: videoIndex);
  }

  /// 已解码 JSON → ResolveResult（防御性双形态核心）。
  ResolveResult parseBody(
    Map<String, dynamic> root, {
    required String tweetId,
    int videoIndex = 0,
  }) {
    // 顶层 code（业务状态码，形态 A/B 均可能出现）：非 200 按 HTTP 同义映射。
    // 类型突变（如字符串 "404"）按字段缺失处理，跳过 code 映射继续结构判定。
    final code = _safeIntOrNull(root['code']);
    if (code != null && code != 200) {
      switch (code) {
        case 404:
          throw TweetNotFound();
        case 403:
        case 429:
          throw RateLimited();
        default:
          throw EndpointDrift();
      }
    }

    final tweet = root['tweet'];
    if (tweet is! Map<String, dynamic>) {
      throw EndpointDrift(); // 结构漂移（备源变更或非预期响应）。
    }

    // 敏感标记：字段名不确定（sensitive/possibly_sensitive/tweet.sensitive），
    // 防御性多处探测；命中即 E06（NSFW 双保险）。
    if (tweet['sensitive'] == true ||
        tweet['possibly_sensitive'] == true ||
        root['sensitive'] == true) {
      throw RestrictedContent();
    }

    final media = tweet['media'];
    final mediaMap = media is Map<String, dynamic> ? media : const <String, dynamic>{};
    final videosRaw = mediaMap['videos'];
    if (videosRaw is! List) {
      throw NotVideoTweet(); // 无 videos 字段：视为非视频推文（图片推文）。
    }
    final videos = videosRaw.whereType<Map<String, dynamic>>().toList();
    if (videos.isEmpty) {
      throw NotVideoTweet();
    }
    final selected = videos[videoIndex.clamp(0, videos.length - 1)];

    // duration：备源单位为秒（num），先乘 1000 再取整（20.5s → 20500ms）。
    // 类型突变 / 非有限值 / 负值按缺失处理（0）；超大值先钳制到 int64 安全域，
    // 防止 Infinity.round() 抛 UnsupportedError 及取整回绕。
    final durationMillis = _durationMillisOf(selected['duration']);

    final variants = <VideoVariant>[];
    final formats = selected['formats'];
    if (formats is List && formats.isNotEmpty) {
      // 形态 B：formats[] 多码率（实测夹具：容器字段名为 container，
      // 防御性兼容 format / content_type 两种别称）。
      for (final raw in formats) {
        if (raw is! Map<String, dynamic>) continue;
        final container =
            _firstStringOf(raw['container'], raw['format'], raw['content_type']);
        if (container != null && !container.contains('mp4')) continue; // HLS 不暴露。
        final url = _safeStringOrNull(raw['url']);
        if (url == null || url.isEmpty) continue;
        final bitrate = _safeIntOrNull(raw['bitrate']) ?? 0;
        var variant = VideoVariant.fromUrl(
          url: url,
          bitrate: bitrate,
          durationMillis: durationMillis,
        );
        // URL 无法提取分辨率时回落到视频条目自带 width/height。
        if (variant.width == null) {
          final w = _safeIntOrNull(selected['width']);
          final h = _safeIntOrNull(selected['height']);
          if (w != null && h != null && w > 0 && h > 0) {
            variant = VideoVariant(
              contentType: variant.contentType,
              bitrate: variant.bitrate,
              url: variant.url,
              width: w,
              height: h,
              estimatedBytes: variant.estimatedBytes,
            );
          }
        }
        variants.add(variant);
      }
    } else {
      // 形态 A：单 url 直链（无 formats 码率列表）——保留 bitrate=0 的单变体，
      // 分辨率从 URL 或条目字段提取，qualityLabel 按分辨率分桶。
      final url = _safeStringOrNull(selected['url']);
      if (url != null && url.isNotEmpty && !url.contains('.m3u8')) {
        variants.add(VideoVariant.fromUrl(
          url: url,
          bitrate: 0,
          durationMillis: durationMillis,
        ));
      }
    }
    if (variants.isEmpty) {
      throw NotVideoTweet();
    }
    // bitrate 降序（码率缺失的单直链自然排末位）。
    variants.sort((a, b) => b.bitrate.compareTo(a.bitrate));

    final author = tweet['author'];
    final authorMap = author is Map<String, dynamic> ? author : const <String, dynamic>{};
    final avatar =
        _firstStringOf(authorMap['avatar_url'], authorMap['avatar']) ?? '';

    // 缩略图：实测字段为 thumbnail_url（防御性兼容 thumbnail 别称），
    // 回落 photos[0].url。
    var thumbnail =
        _firstStringOf(selected['thumbnail_url'], selected['thumbnail']) ?? '';
    if (thumbnail.isEmpty) {
      final photos = mediaMap['photos'];
      if (photos is List && photos.isNotEmpty) {
        final first = photos.first;
        if (first is Map<String, dynamic>) {
          thumbnail = _safeStringOrNull(first['url']) ?? '';
        }
      }
    }

    return ResolveResult(
      parserVersion: kFxTwitterParserVersion,
      tweet: TweetMeta(
        tweetId: _safeStringOrNull(tweet['id']) ?? tweetId,
        userName: _safeStringOrNull(authorMap['name']) ?? '',
        screenName: _safeStringOrNull(authorMap['screen_name']) ?? '',
        avatarUrl: avatar,
        text: _safeStringOrNull(tweet['text']) ?? '',
        // 备源时间双形态：优先 created_timestamp（unix 秒，实测存在），
        // 回落 ISO 字符串，再回落 tweet.created_at 的 Twitter 英文格式解析。
        createdAt: _parseCreatedAt(tweet),
        thumbnailUrl: thumbnail,
        durationMillis: durationMillis,
        possiblySensitive: false, // true 已在上方提前抛 E06。
        videoCount: videos.length,
        variants: variants,
      ),
    );
  }

  /// 备源创建时间解析（三重防御）：
  /// 1. created_timestamp（unix 秒，实测夹具存在）；
  /// 2. ISO 8601 字符串；
  /// 3. Twitter 英文格式 "Wed May 15 06:57:40 +0000 2024" 手工解析；
  /// 全部失败回落 epoch（历史页仅作展示，不参与判定）。
  static DateTime _parseCreatedAt(Map<String, dynamic> tweet) {
    // 超界秒值（×1000 超出 DateTime 毫秒域上限 8640000000000000 会抛
    // RangeError）与类型突变按缺失处理，继续走后续回落。
    final unixSeconds = _safeIntOrNull(tweet['created_timestamp']);
    if (unixSeconds != null &&
        unixSeconds > 0 &&
        unixSeconds <= _kMaxEpochSeconds) {
      return DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000, isUtc: true);
    }
    final createdAt = _safeStringOrNull(tweet['created_at']) ?? '';
    final iso = DateTime.tryParse(createdAt);
    if (iso != null) return iso;
    final match = RegExp(
      r'^[A-Za-z]{3} ([A-Za-z]{3}) (\d{1,2}) (\d{2}):(\d{2}):(\d{2}) \+0000 (\d{4})$',
    ).firstMatch(createdAt);
    if (match != null) {
      final months = <String, int>{
        'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
        'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
      };
      final month = months[match.group(1)!];
      final day = int.tryParse(match.group(2)!);
      final hour = int.tryParse(match.group(3)!);
      final minute = int.tryParse(match.group(4)!);
      final second = int.tryParse(match.group(5)!);
      final year = int.tryParse(match.group(6)!);
      if (month != null &&
          day != null && hour != null && minute != null && second != null && year != null) {
        return DateTime.utc(year, month, day, hour, minute, second);
      }
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}

// ---------------------------------------------------------------------------
// 防御式字段读取（跨信任边界）：类型突变按字段缺失处理，绝不抛 TypeError。
// 备源与主源同规：结构漂移必须落入既有 ParseError 分类（E04/E05/E07），
// 而不是以 Error 形态逃逸契约被编排层兜底成 E02。
// ---------------------------------------------------------------------------

/// int64 上限（超大 double 取整 / duration 钳制的安全域边界）。
const int _kMaxInt64 = 9223372036854775807;

/// DateTime 可表示的毫秒域上限（±8640000000000000，超界抛 RangeError），
/// 换算为秒级上限用于 created_timestamp 预检。
const int _kMaxEpochSeconds = 8640000000000000 ~/ 1000;

/// duration（秒）安全域上限：×1000 后仍严格小于 int64 上限，可安全取整。
const double _kMaxDurationSeconds = 9223372036854775.0;

/// 数值字段防御式读取：非 num / 非有限值（JSON `1e999` 解出 Infinity）/
/// 超出 int64 域的 double 一律安全化——类型突变返回 null（按字段缺失）。
int? _safeIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is double) {
    if (!value.isFinite) return null;
    if (value >= _kMaxInt64) return _kMaxInt64;
    if (value <= -_kMaxInt64) return -_kMaxInt64;
    return value.toInt();
  }
  return null;
}

/// 字符串字段防御式读取：类型突变（如数字变字符串字段）返回 null（按字段缺失）。
String? _safeStringOrNull(Object? value) => value is String ? value : null;

/// 依序取第一个 String 形态的候选值（别称字段兼容，非 String 形态跳过）。
String? _firstStringOf(Object? a, Object? b, [Object? c]) {
  if (a is String) return a;
  if (b is String) return b;
  return c is String ? c : null;
}

/// duration（秒）→ 毫秒：类型突变（非 num）/ NaN / 负值按 0 处理；
/// 正向超大值（含 +Infinity，JSON `1e999` 解出）钳制到 int64 安全域后再
/// 乘 1000 取整，防止 Infinity.round() 抛 UnsupportedError 与取整回绕为负。
int _durationMillisOf(Object? raw) {
  if (raw is! num || raw.isNaN || raw < 0) return 0;
  final seconds =
      raw.toDouble() > _kMaxDurationSeconds ? _kMaxDurationSeconds : raw.toDouble();
  final ms = seconds * 1000;
  return ms >= _kMaxInt64 ? _kMaxInt64 : ms.round();
}

/// 备源原始响应快照（status + body；content-type 恒为 JSON 语义无需单独保留）。
class FxRawResponse {
  const FxRawResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}
