/// Syndication 主解析器（DESIGN §6.3 解析路径的 TweetParser 主实现）。
///
/// 分类规则（§6.6 七类中的解析侧五类 + 网络映射；状态码分类先于内容形态）：
/// - HTTP 404 / 200+空`{}` / 200 且 content-type 为 html（dogpage）→ TweetNotFound（E04）；
/// - HTTP 429 / 403（含 HTML 挑战页）→ RateLimited（E03，403 不归"锁推"）；
/// - HTTP 5xx（含 HTML 错误页）/ dio 网络异常 → NetworkTimeout（E02）；
/// - 其余 4xx / 200 非 JSON / __typename 守卫不过 / 关键字段缺失 → EndpointDrift（E07）；
/// - possibly_sensitive == true → RestrictedContent（E06）；
/// - mediaDetails 缺失 / 类型突变 / 无 video/animated_gif 条目（或无可下载 mp4 变体）
///   → NotVideoTweet（E05，error_codes.md 实现注记：纯文本推文 mediaDetails 可整体缺失）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:clipvault/core/error.dart';
import 'package:clipvault/core/token.dart';

import 'endpoint_config.dart';
import 'models.dart';
import 'syndication_client.dart';

/// 主源解析版本标识（ResolveResult.parserVersion）。
const String kSyndicationParserVersion = 'syndication-v1';

/// Syndication tweet-result → TweetMeta 的主实现。
class SyndicationParser implements TweetParser {
  SyndicationParser({
    required this._client,
    required this.config,
    this.langs = const ['zh-CN', 'en'],
  });

  final SyndicationClient _client;

  /// 当前端点配置（远端热更后由编排层重建 Parser，见 §6.7）。
  final EndpointConfig config;

  /// lang 回落序列（§6.1）。
  final List<String> langs;

  @override
  Future<ResolveResult> resolve(String tweetId, {int videoIndex = 0}) async {
    // token 本地计算（<1ms，§6.8），与 yt-dlp master 一致（§6.2）。
    final token = getToken(tweetId);
    final SyndicationResponse response;
    try {
      response = await _client.fetchWithLangFallback(
        tweetId: tweetId,
        token: token,
        config: config,
        langs: langs,
      );
    } on DioException catch (error) {
      // 网络层异常统一归 E02（§6.6），调用方只见 ParseError。
      throw mapDioExceptionToParseError(error);
    }
    return parseResponse(
      response,
      tweetId: tweetId,
      videoIndex: videoIndex,
      config: config,
    );
  }

  /// 纯分类+映射（无 IO）：夹具回放测试与 resolve 共用的唯一判定入口。
  ///
  /// 抛出 core/error.dart 的 ParseError 子类；成功返回 ResolveResult。
  ResolveResult parseResponse(
    SyndicationResponse response, {
    required String tweetId,
    int videoIndex = 0,
    EndpointConfig? config,
  }) {
    final guard = (config ?? this.config).driftGuard;

    // 状态码分类先于内容形态（isHtml）判定：403/429/5xx 携带的 HTML 挑战页/
    // 错误页必须按状态码归类（E03/E02），否则备源切换与重试语义会被 E04 掩盖。
    switch (response.statusCode) {
      case 200:
        break; // 进入内容形态与 body 判定。
      case 404:
        throw TweetNotFound();
      case 403:
      case 429:
        throw RateLimited(); // 403 在解析语境归风控/限频（§1.4 规避清单）。
      case >= 500:
        throw NetworkTimeout(); // 上游瞬时故障，按可重试网络类处理。
      default:
        // 其余 4xx：与契约无关的客户端错误，视为漂移触发配置刷新检查。
        throw EndpointDrift();
    }

    // dogpage HTML（content-type html）：仅在 2xx（200）语境判 E04——
    // 实测错误页可能伴随 200 返回（§6.1）；带错误状态码的 HTML 已由上方
    // switch 按状态码归类（403/429→E03、5xx→E02、404→E04）。
    if (response.isHtml) {
      throw TweetNotFound();
    }

    final body = response.body.trim();
    // 无 token 行为：HTTP 200 + 空 JSON {}（§6.1 实测边界）→ E04。
    if (body.isEmpty || body == '{}' || body == 'null') {
      throw TweetNotFound();
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw EndpointDrift(); // 200 但非 JSON：结构性漂移。
    }
    if (decoded is! Map<String, dynamic>) {
      throw EndpointDrift();
    }
    return _mapTweet(decoded, tweetId: tweetId, videoIndex: videoIndex, guard: guard);
  }

  ResolveResult _mapTweet(
    Map<String, dynamic> root, {
    required String tweetId,
    required int videoIndex,
    required DriftGuard guard,
  }) {
    // E07 守卫：__typename 必须等于配置值（默认 'Tweet'）。
    if (root['__typename'] != guard.typenameEquals) {
      throw EndpointDrift();
    }
    // E07 守卫：关键字段路径必须存在（点号分隔遍历，null 即缺失）。
    // 注意 mediaDetails 不在守卫范围（出厂配置已移除）：纯文本推文该字段
    // 整体缺失是合法形态，必须走 E05 而非 E07（error_codes.md 实现注记）。
    for (final path in guard.requiredFields) {
      if (_resolvePath(root, path) == null) {
        throw EndpointDrift();
      }
    }

    // E06：possibly_sensitive == true → 阻断（UI 侧不载缩略图，§8.5）。
    if (root['possibly_sensitive'] == true) {
      throw RestrictedContent();
    }

    // mediaDetails 遍历（多视频推文含多个 video 条目，§6.3 实测确认）。
    // 缺失 / null / 类型突变（非 List）统一按空列表处理 → 自然落入 E05
    // （error_codes.md 实现注记：mediaDetails 缺失/空数组/无 video 条目
    // 三者统一归 NotVideoTweet，不得误报 E07）。
    final mediaDetailsRaw = root['mediaDetails'];
    final mediaDetails = mediaDetailsRaw is List ? mediaDetailsRaw : const <dynamic>[];
    final videoEntries = mediaDetails
        .whereType<Map<String, dynamic>>()
        .where((m) {
          final type = m['type'];
          return type == 'video' || type == 'animated_gif'; // GIF 归入可下载。
        })
        .toList();
    if (videoEntries.isEmpty) {
      throw NotVideoTweet();
    }
    final selected = videoEntries[videoIndex.clamp(0, videoEntries.length - 1)];

    final videoInfo = selected['video_info'];
    if (videoInfo is! Map<String, dynamic>) {
      throw EndpointDrift();
    }
    // duration_millis：类型突变/非有限值（JSON 1e999 解出 Infinity）/负值
    // 一律按缺失处理（0）——resolve.schema.json 约束 durationMillis >= 0。
    final durationRaw = _safeIntOrNull(videoInfo['duration_millis']);
    final durationMillis =
        durationRaw != null && durationRaw > 0 ? durationRaw : 0;
    final variantsRaw = videoInfo['variants'];
    if (variantsRaw is! List) {
      throw EndpointDrift();
    }

    // 仅收集 content_type == video/mp4 且 bitrate > 0 的变体（HLS 不暴露，§12.9）。
    final variants = <VideoVariant>[];
    for (final raw in variantsRaw) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['content_type'] != 'video/mp4') continue;
      // 防御式取值：字段类型突变按缺失处理（bitrate→0 该变体被过滤），
      // 绝不抛 TypeError 逃逸 ParseError 契约（E07 场景就是结构漂移）。
      final bitrate = _safeIntOrNull(raw['bitrate']) ?? 0;
      final url = _safeStringOrNull(raw['url']);
      if (bitrate <= 0 || url == null || url.isEmpty) continue;
      variants.add(VideoVariant.fromUrl(
        url: url,
        bitrate: bitrate,
        durationMillis: durationMillis,
      ));
    }
    if (variants.isEmpty) {
      // 视频条目存在但无满足条件的 mp4 变体（如 HLS-only 片源）：
      // 用户视角与 E05 一致（无可下载视频），见偏离说明。
      throw NotVideoTweet();
    }
    // 按 bitrate 降序（§5.1）。
    variants.sort((a, b) => b.bitrate.compareTo(a.bitrate));

    final user = root['user'];
    final userMap = user is Map<String, dynamic> ? user : const <String, dynamic>{};
    // 正文：note_tweet 优先（§5.1）；字符串字段类型突变按缺失处理。
    final noteTweet = root['note_tweet'];
    final noteText = noteTweet is Map<String, dynamic>
        ? _safeStringOrNull(noteTweet['text'])
        : null;
    final text = (noteText == null || noteText.isEmpty)
        ? _safeStringOrNull(root['text']) ?? ''
        : noteText;

    return ResolveResult(
      parserVersion: kSyndicationParserVersion,
      tweet: TweetMeta(
        tweetId: _safeStringOrNull(root['id_str']) ?? tweetId,
        userName: _safeStringOrNull(userMap['name']) ?? '',
        screenName: _safeStringOrNull(userMap['screen_name']) ?? '',
        avatarUrl: _safeStringOrNull(userMap['profile_image_url_https']) ?? '',
        text: text,
        createdAt:
            DateTime.tryParse(_safeStringOrNull(root['created_at']) ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
        thumbnailUrl: _safeStringOrNull(selected['media_url_https']) ?? '',
        durationMillis: durationMillis,
        possiblySensitive: false, // true 已在上方提前抛 E06。
        videoCount: videoEntries.length,
        variants: variants,
      ),
    );
  }

  /// 点号分隔路径取值；任一级缺失返回 null。
  static Object? _resolvePath(Map<String, dynamic> root, String path) {
    Object? current = root;
    for (final segment in path.split('.')) {
      if (current is! Map<String, dynamic>) return null;
      current = current[segment];
    }
    return current;
  }
}

// ---------------------------------------------------------------------------
// 防御式字段读取（跨信任边界）：类型突变按字段缺失处理，绝不抛 TypeError。
// E07 的设计场景是「上游结构漂移」，但硬强转恰恰会让类型突变以 Error
// 形态逃逸 ParseError 契约（被编排层兜底成 E02 网络错误）；此处统一按
// 字段缺失降级，让漂移落入既有分类（E07 守卫 / E05 非视频推文）。
// ---------------------------------------------------------------------------

/// int64 上限（超大 double 取整的钳制边界，防越界取整异常/回绕）。
const int _kMaxInt64 = 9223372036854775807;

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

/// dio 网络异常 → ParseError 映射（解析编排层与测试共用）。
///
/// 网络层异常（连接/接收超时/DNS/连接重置等）统一归 E02 NetworkTimeout
/// （退避 3 次自动重试后透出，§6.6）。
ParseError mapDioExceptionToParseError(DioException error) {
  return NetworkTimeout();
}
