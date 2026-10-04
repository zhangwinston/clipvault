/// 解析器应用级装配（原位于 ui/home/home_screen.dart，2026-10-04 迁出）：
/// 端点配置仓库 + 主备源解析器 Provider + 403/410 直链刷新助手。
///
/// 迁出原因：下载引擎装配（ui/downloads/task_tile.dart 的
/// downloadEngineProvider）需要 tweetParserProvider 实现 UrlRefresher
///（403/410 直链过期的自动重解析，DESIGN §4.3——此前生产从未接线，
/// 属生产接线缺陷：旧任务直链过期后一键重试立即 urlExpired 失败）。
/// Provider 属应用级设施，置于 parse 层供首页/设置/下载三侧共用，
/// 避免 ui 层文件相互 import 成环。
library;

import 'package:clipvault/core/app_http.dart' show createAppDio;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'endpoint_config.dart';
import 'fxtwitter_parser.dart';
import 'models.dart';
import 'resilient_parser.dart';
import 'syndication_client.dart';
import 'syndication_parser.dart';

/// prefs 缓存（版本更高原子替换）→ 后台远端拉取（remoteUrl 默认空=关闭）。
final FutureProvider<EndpointConfigRepository> endpointConfigRepositoryProvider =
    FutureProvider<EndpointConfigRepository>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final repo = EndpointConfigRepository(
    dio: createAppDio(),
    prefs: prefs,
    assetLoader: (path) => rootBundle.loadString(path),
  );
  await repo.load();
  return repo;
});

/// 解析器注入点：生产装配主备源编排解析器（ResilientParser）——
/// 主源 syndication + 备源 fxtwitter（随端点配置 fallback.enabled 开关，
/// 默认关闭即行为等同单主源）；端点配置取自配置仓库当前生效版本
/// （§6.7；E07 刷新成功后 invalidate 重建，新配置生效）。
/// 测试以 overrideWith 注入假解析器（FutureProvider 接受同步返回值）。
final FutureProvider<TweetParser> tweetParserProvider =
    FutureProvider<TweetParser>((ref) async {
  final repo = await ref.watch(endpointConfigRepositoryProvider.future);
  return ResilientParser(
    primary: SyndicationParser(
      client: SyndicationClient(dio: createAppDio()),
      config: repo.current,
    ),
    fallback: FxTwitterParser(dio: createAppDio(), config: repo.current),
  );
});

/// 403/410 直链过期时按 (tweetId, bitrate) 刷新直链（UrlRefresher 契约，
/// DESIGN §4.3）。精确匹配码率：
/// - 命中同码率多容器时优先 mp4（引擎直取字节流，m3u8 不适用）；
/// - 未命中（X 重转码变更码率档）返回 null → failed(urlExpired)：
///   不得换近似码率——.part 字节流属于旧编码，换档续传会产出损坏文件；
/// - 解析抛错（网络/端点故障）返回 null，一键重试会再次尝试。
///
/// 多视频推文按默认 0 号视频尽力而为（引擎任务未持久化 videoIndex）。
Future<String?> refreshVariantUrl(
    TweetParser parser, String tweetId, int bitrate) async {
  final ResolveResult result;
  try {
    result = await parser.resolve(tweetId);
  } catch (_) {
    return null;
  }
  VideoVariant? best;
  for (final v in result.tweet.variants) {
    if (v.bitrate != bitrate) continue;
    final bestIsMp4 = best?.contentType == VariantContentType.mp4;
    final vIsMp4 = v.contentType == VariantContentType.mp4;
    if (best == null || (bestIsMp4 ? false : vIsMp4)) {
      best = v;
    }
  }
  return best?.url;
}
