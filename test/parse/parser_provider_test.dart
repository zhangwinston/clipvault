/// refreshVariantUrl 单元测试（403/410 直链刷新匹配逻辑，§4.3）：
/// 精确码率命中 / 同码率优先 mp4 / 未命中返回 null（不得换近似码率）/
/// 解析抛错返回 null。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/parse/models.dart';
import 'package:clipvault/parse/parser_provider.dart';

class _FakeParser implements TweetParser {
  _FakeParser(this.result);
  final Object result; // ResolveResult 或异常

  @override
  Future<ResolveResult> resolve(String tweetId, {int videoIndex = 0}) async {
    if (result is Exception) throw result as Exception;
    return result as ResolveResult;
  }
}

ResolveResult _result(List<VideoVariant> variants) => ResolveResult(
      tweet: TweetMeta(
        tweetId: '1790637656616943991',
        userName: 'a',
        screenName: 'a',
        avatarUrl: 'https://pbs.twimg.com/a.jpg',
        text: 't',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        thumbnailUrl: 'https://pbs.twimg.com/t.jpg',
        durationMillis: 90000,
        possiblySensitive: false,
        videoCount: 1,
        variants: variants,
      ),
      parserVersion: 'fake-v1',
    );

VideoVariant _variant(int bitrate,
        {VariantContentType contentType = VariantContentType.mp4,
        String url = 'https://video.twimg.com/v.mp4'}) =>
    VideoVariant(
      contentType: contentType,
      bitrate: bitrate,
      url: url,
      estimatedBytes: 1024,
    );

void main() {
  const tweetId = '1790637656616943991';

  test('精确码率命中 → 返回该变体直链', () async {
    final parser = _FakeParser(_result([
      _variant(832000, url: 'https://v/480.mp4'),
      _variant(2176000, url: 'https://v/720.mp4'),
      _variant(3200000, url: 'https://v/1080.mp4'),
    ]));
    expect(await refreshVariantUrl(parser, tweetId, 2176000),
        'https://v/720.mp4');
  });

  test('同码率多容器 → 优先 mp4（引擎直取字节流，hls 不适用）', () async {
    final parser = _FakeParser(_result([
      _variant(2176000, contentType: VariantContentType.hls,
          url: 'https://v/720.m3u8'),
      _variant(2176000, url: 'https://v/720.mp4'),
    ]));
    expect(await refreshVariantUrl(parser, tweetId, 2176000),
        'https://v/720.mp4');
  });

  test('码率未命中（X 重转码变更码率档）→ null，不换近似码率', () async {
    final parser = _FakeParser(_result([
      _variant(832000),
      _variant(2160000), // 旧 2176000 档已不存在
    ]));
    expect(await refreshVariantUrl(parser, tweetId, 2176000), isNull);
  });

  test('解析抛错（网络/端点故障）→ null（重试时再试）', () async {
    final parser = _FakeParser(Exception('network'));
    expect(await refreshVariantUrl(parser, tweetId, 2176000), isNull);
  });
}
