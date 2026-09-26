/// 主备源编排解析器（DESIGN §6.5 降级备援的实现接线）。
///
/// 主源（syndication）抛出可降级错误（RateLimited / EndpointDrift）且
/// 备源经端点配置启用（fallback.enabled）时，自动改走备源（fxtwitter）
/// 一次；备源自身失败则透出其错误（信息更近因）。
///
/// 话术诚实性约束（app_strings.dart errRateLimitedHint）：
/// 在 fallback.enabled 默认关闭的阶段，UI 文案不得声称「已尝试备用解析源」；
/// 远端配置打开开关后，本编排器使该降级真实发生。
library;

import 'package:clipvault/core/error.dart';

import 'fxtwitter_parser.dart';
import 'models.dart';

/// 可降级错误集合：主源被风控（E03）或结构漂移（E07）时备源有价值；
/// 其余错误（404/非视频/受限内容等）与源无关，降级无意义。
bool _degradable(ParseError error) =>
    error is RateLimited || error is EndpointDrift;

class ResilientParser implements TweetParser {
  ResilientParser({required this.primary, required this.fallback});

  /// 主源解析器（SyndicationParser）。
  final TweetParser primary;

  /// 备源解析器（FxTwitterParser；isEnabled 随端点配置）。
  final FxTwitterParser fallback;

  @override
  Future<ResolveResult> resolve(String tweetId, {int videoIndex = 0}) async {
    try {
      return await primary.resolve(tweetId, videoIndex: videoIndex);
    } on ParseError catch (error) {
      if (!_degradable(error) || !fallback.isEnabled) {
        rethrow;
      }
      // 降级备源一次：成功即返回；失败透出备源错误。
      return await fallback.resolve(tweetId, videoIndex: videoIndex);
    }
  }
}
