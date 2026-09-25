/// 解析域模型（DESIGN §5.1）与 TweetParser 可替换接口（DESIGN §6.5）。
///
/// 本文件是解析层的字段级契约源：
/// - [VideoVariant] / [TweetMeta] / [ResolveResult] 字段与 DESIGN §5.1 一一对应；
/// - [TweetParser] 为可替换解析接口（预留方案 C/B 服务端解析与备源插拔）；
/// - 所有 Parser 实现的统一产出为 [ResolveResult]（contracts/resolve.schema.json
///   的 Dart 侧），解析失败时抛出 core/error.dart 的 sealed ParseError（七类）。
library;

/// 变体容器类型。实际仅暴露 mp4（HLS 裁剪理由见 DESIGN §12.9）。
enum VariantContentType { mp4, hls }

/// 安全体积估算：bitrate × durationMillis / 8000。
///
/// int 乘法在 int64 域内会静默回绕（负值违反 resolve.schema.json 的
/// estimatedBytes minimum: 0；畸形/恶意响应可给出接近 int64 上限的
/// duration_millis）。两个因子先做 2^53 预检：任一超界直接钳制到 int64
/// 上限；域内改用 double 乘法（不回绕，估算字段容忍双精度误差），
/// 结果再钳制非负，保证产物恒为 [0, int64 max]。
int _estimateBytes(int bitrate, int durationMillis) {
  const int maxSafeFactor = 9007199254740992; // 2^53
  const int maxInt64 = 9223372036854775807;
  if (bitrate > maxSafeFactor || durationMillis > maxSafeFactor) {
    return maxInt64;
  }
  final double bytes = bitrate.toDouble() * durationMillis.toDouble() / 8000;
  if (bytes >= maxInt64) return maxInt64;
  final int rounded = bytes.round();
  return rounded > 0 ? rounded : 0;
}

/// 从 content_type 字符串映射枚举（video/mp4 → mp4，m3u8 系 → hls）。
VariantContentType? variantContentTypeFromMime(String? mime) {
  switch (mime) {
    case 'video/mp4':
      return VariantContentType.mp4;
    case 'application/x-mpegURL':
    case 'application/vnd.apple.mpegurl':
      return VariantContentType.hls;
    default:
      return null;
  }
}

/// 从 video.twimg.com URL 路径 `/vid/avc1/1280x720/` 提取分辨率。
/// DESIGN §6.3：响应无分辨率字段，分辨率只能从 URL 正则提取。
/// 返回 (width, height)；无法提取时返回 null。
(int, int)? extractResolution(String url) {
  final match = RegExp(r'/(\d{2,5})x(\d{2,5})/').firstMatch(url);
  if (match == null) return null;
  final width = int.tryParse(match.group(1)!);
  final height = int.tryParse(match.group(2)!);
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return (width, height);
}

/// 单个可下载视频变体（一条 video.twimg.com 直链，含会过期的签名参数）。
class VideoVariant {
  const VideoVariant({
    required this.contentType,
    required this.bitrate,
    required this.url,
    required this.estimatedBytes,
    this.width,
    this.height,
  });

  factory VideoVariant.fromUrl({
    required String url,
    required int bitrate,
    required int durationMillis,
    VariantContentType contentType = VariantContentType.mp4,
  }) {
    final resolution = extractResolution(url);
    return VideoVariant(
      contentType: contentType,
      bitrate: bitrate,
      url: url,
      width: resolution?.$1,
      height: resolution?.$2,
      // 量纲说明：bitrate(bps) × durationMillis / 8000 = 字节数（ms→s、bit→byte）。
      // DESIGN §5.1 注释简写为 "bitrate × durationMillis / 8"，但其 §4.2 示例
      // （2.18 Mbps · 约 24.5 MB ⇒ 90s 视频）只能由 /8000 得出，按示例语义实现。
      estimatedBytes: _estimateBytes(bitrate, durationMillis),
    );
  }

  final VariantContentType contentType;

  /// 码率 bps，如 2176000。
  final int bitrate;

  /// video.twimg.com 直链（含签名参数，会过期）。
  final String url;

  /// URL /(\d+)x(\d+)/ 正则提取的宽；缺失为 null。
  final int? width;

  /// URL /(\d+)x(\d+)/ 正则提取的高；缺失为 null。
  final int? height;

  /// 预估体积（字节）。
  final int estimatedBytes;

  /// '1080p (Full HD)' / '720p (HD)' / '480p (SD)' / '360p' 四档标签
  /// （contracts/resolve.schema.json 的 pattern 约束为这四个字面量）。
  /// height 按档位分桶（>=1080/720/480/<480）；分辨率缺失时按码率映射兜底（§4.2）。
  String get qualityLabel {
    final resolvedHeight = height ?? _heightFromBitrate() ?? 0;
    if (resolvedHeight >= 1080) return '1080p (Full HD)';
    if (resolvedHeight >= 720) return '720p (HD)';
    if (resolvedHeight >= 480) return '480p (SD)';
    return '360p';
  }

  int? _heightFromBitrate() {
    if (bitrate <= 0) return null;
    if (bitrate >= 3000000) return 1080;
    if (bitrate >= 1200000) return 720;
    if (bitrate >= 500000) return 480;
    return 360;
  }

  /// tweetJson 快照序列化（DESIGN §5.3）。
  /// 键名与 contracts/resolve.schema.json 的 VideoVariant 定义一致
  /// （required: contentType/bitrate/url/estimatedBytes/qualityLabel，
  /// additionalProperties: false）。
  Map<String, Object?> toJson() => <String, Object?>{
        'contentType': contentType.name,
        'bitrate': bitrate,
        'url': url,
        'width': width,
        'height': height,
        'estimatedBytes': estimatedBytes,
        'qualityLabel': qualityLabel,
      };

  factory VideoVariant.fromJson(Map<String, dynamic> json) {
    // contentType 正常写入的是枚举名（'mp4'/'hls'，见 toJson）；
    // 防御性兼容 MIME 形态（'video/mp4' 等，经 variantContentTypeFromMime 归一）。
    // 写法注意：`as String? ==` 连写会被解析器把 `?` 当作条件表达式起点，
    // 必须先落局部变量再比较。
    final rawType = json['contentType'] as String?;
    final VariantContentType contentType;
    if (rawType == 'hls') {
      contentType = VariantContentType.hls;
    } else {
      contentType = variantContentTypeFromMime(rawType) ?? VariantContentType.mp4;
    }
    return VideoVariant(
      contentType: contentType,
      bitrate: (json['bitrate'] as num?)?.toInt() ?? 0,
      url: json['url'] as String? ?? '',
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      estimatedBytes: (json['estimatedBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 推文元数据（一次解析的完整产出，历史页离线渲染的数据源）。
class TweetMeta {
  TweetMeta({
    required this.tweetId,
    required this.userName,
    required this.screenName,
    required this.avatarUrl,
    required this.text,
    required this.createdAt,
    required this.thumbnailUrl,
    required this.durationMillis,
    required this.possiblySensitive,
    required this.videoCount,
    required List<VideoVariant> variants,
  }) : variants = List.unmodifiable(variants);

  final String tweetId;

  /// user.name
  final String userName;

  /// user.screen_name
  final String screenName;

  /// user.profile_image_url_https
  final String avatarUrl;

  /// 正文（note_tweet 优先，展示层两行截断）。
  final String text;

  final DateTime createdAt;

  /// mediaDetails[].media_url_https（多视频为当前选中项）。
  final String thumbnailUrl;

  /// video_info.duration_millis
  final int durationMillis;

  /// possibly_sensitive == true 时 UI 不加载缩略图（NSFW 双保险，§8.5）。
  final bool possiblySensitive;

  /// 多视频推文 >1 时 UI 出 Chip（mediaDetails 遍历计数）。
  final int videoCount;

  /// 仅 mp4、bitrate>0（备源防御形态除外）、按 bitrate 降序。
  final List<VideoVariant> variants;

  Map<String, Object?> toJson() => <String, Object?>{
        'tweetId': tweetId,
        'userName': userName,
        'screenName': screenName,
        'avatarUrl': avatarUrl,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
        'thumbnailUrl': thumbnailUrl,
        'durationMillis': durationMillis,
        'possiblySensitive': possiblySensitive,
        'videoCount': videoCount,
        'variants': variants.map((v) => v.toJson()).toList(),
      };

  factory TweetMeta.fromJson(Map<String, dynamic> json) => TweetMeta(
        tweetId: json['tweetId'] as String? ?? '',
        userName: json['userName'] as String? ?? '',
        screenName: json['screenName'] as String? ?? '',
        avatarUrl: json['avatarUrl'] as String? ?? '',
        text: json['text'] as String? ?? '',
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        thumbnailUrl: json['thumbnailUrl'] as String? ?? '',
        durationMillis: (json['durationMillis'] as num?)?.toInt() ?? 0,
        possiblySensitive: json['possiblySensitive'] == true,
        videoCount: (json['videoCount'] as num?)?.toInt() ?? 0,
        variants: ((json['variants'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(VideoVariant.fromJson)
            .toList(),
      );
}

/// 契约信封：所有 Parser 实现的统一产出（contracts/resolve.schema.json 的 Dart 侧）。
class ResolveResult {
  const ResolveResult({required this.tweet, required this.parserVersion});

  final TweetMeta tweet;

  /// 'syndication-v1' | 'fxtwitter-v1'
  final String parserVersion;

  Map<String, Object?> toJson() => <String, Object?>{
        'tweet': tweet.toJson(),
        'parserVersion': parserVersion,
      };
}

/// 可替换解析接口（DESIGN §4.1/§6.5）。
///
/// 实现契约：
/// - 入参为已通过 url_extract 校验的 Tweet ID（E01 在编排层先行判定，零网络请求）；
/// - 成功返回 [ResolveResult]；
/// - 失败抛出 core/error.dart 的 sealed ParseError 子类（七类之一）；
/// - [videoIndex] 用于多视频推文选择 mediaDetails 中的第 N 个视频（默认 0，
///   越界时钳制到合法区间），为可选扩展参数，不影响单参调用契约。
abstract interface class TweetParser {
  Future<ResolveResult> resolve(String tweetId, {int videoIndex});
}
