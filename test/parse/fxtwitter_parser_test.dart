/// FxTwitterParser 备源防御性双形态测试（DESIGN §11.1、§6.4、§12-13）。
///
/// 覆盖：真实夹具回放（formats[] 多码率形态）、单 url 直链形态、
/// 顶层 code 映射、错误分类（E03/E04/E05/E06）、HTTP 状态映射。
/// 全部本地 mock，零真实网络。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/core/error.dart';
import 'package:clipvault/parse/endpoint_config.dart';
import 'package:clipvault/parse/fxtwitter_parser.dart';
import 'package:clipvault/parse/models.dart';

import 'syndication_parser_test.dart' show StubAdapter, StubResponse, readFixture;

FxTwitterParser buildParser() =>
    FxTwitterParser(dio: Dio(), config: EndpointConfig.builtIn());

void main() {
  final parser = buildParser();

  test('备源默认关闭（endpoints 配置 fallback.enabled=false，§6.4）', () {
    expect(parser.isEnabled, isFalse);
  });

  group('真实夹具回放：fxtwitter_status_ok（formats[] 多码率形态）', () {
    test('字段映射完整', () {
      final result = parser.parseBody(
        jsonDecode(readFixture('fxtwitter_status_ok.json')) as Map<String, dynamic>,
        tweetId: '1790637656616943991',
      );

      expect(result.parserVersion, kFxTwitterParserVersion);
      final tweet = result.tweet;
      expect(tweet.tweetId, '1790637656616943991');
      expect(tweet.userName, 'Historic Vids');
      expect(tweet.screenName, 'historyinmemes');
      expect(tweet.avatarUrl, 'https://pbs.twimg.com/profile_images/1648334723725361152/ev7V1230_200x200.jpg');
      expect(tweet.text, 'One of the most intense moments in history');
      // created_timestamp（unix 秒）优先于 Twitter 英文格式 created_at。
      expect(tweet.createdAt, DateTime.utc(2024, 5, 15, 6, 57, 40));
      expect(
        tweet.thumbnailUrl,
        'https://pbs.twimg.com/amplify_video_thumb/1790637589910654976/img/jyhLQQZkq-lJJ9fN.jpg',
      );
      expect(tweet.durationMillis, 15488); // 15.488s → ms
      expect(tweet.videoCount, 1);
    });

    test('variants：container=mp4 过滤、码率降序、分辨率提取', () {
      final result = parser.parseBody(
        jsonDecode(readFixture('fxtwitter_status_ok.json')) as Map<String, dynamic>,
        tweetId: '1790637656616943991',
      );
      final variants = result.tweet.variants;

      expect(variants.length, 3); // m3u8 formats 条目被排除
      expect(variants.map((v) => v.bitrate), [2176000, 832000, 288000]);
      expect(variants.every((v) => v.contentType == VariantContentType.mp4), isTrue);
      expect(variants.first.width, 728);
      expect(variants.first.height, 720);
      expect(variants.first.qualityLabel, '720p (HD)');
      expect(variants.first.estimatedBytes, 2176000 * 15488 ~/ 8000);
    });
  });

  group('形态 A：videos[] 单 url 直链（无 formats 码率列表）', () {
    Map<String, dynamic> formABody() => <String, dynamic>{
          'code': 200,
          'tweet': <String, dynamic>{
            'id': '1798765432109876543',
            'text': 'single direct link form',
            'author': <String, dynamic>{
              'name': 'Nature Clips',
              'screen_name': 'NatureClips',
              'avatar_url': 'https://pbs.twimg.com/profile_images/1/a_200x200.jpg',
            },
            'created_at': 'Sat Jun 08 14:22:31 +0000 2024',
            'media': <String, dynamic>{
              'videos': <dynamic>[
                <String, dynamic>{
                  'url':
                      'https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/1280x720/a.mp4?tag=12',
                  'thumbnail_url': 'https://pbs.twimg.com/ext_tw_video_thumb/1/img.jpg',
                  'duration': 20.5,
                  'type': 'video',
                },
              ],
            },
          },
        };

    test('保留单变体（bitrate=0），分辨率从 URL 提取', () {
      final result = parser.parseBody(formABody(), tweetId: '1798765432109876543');
      final variants = result.tweet.variants;

      expect(variants.length, 1);
      expect(variants.single.bitrate, 0);
      expect(variants.single.width, 1280);
      expect(variants.single.height, 720);
      expect(variants.single.qualityLabel, '720p (HD)');
      expect(result.tweet.durationMillis, 20500);
      expect(result.tweet.thumbnailUrl, contains('ext_tw_video_thumb'));
    });

    test('created_at Twitter 英文格式可解析（无 created_timestamp 时回落）', () {
      final result = parser.parseBody(formABody(), tweetId: '1798765432109876543');
      expect(result.tweet.createdAt, DateTime.utc(2024, 6, 8, 14, 22, 31));
    });
  });

  group('顶层 code 与错误分类', () {
    test('code=404 → TweetNotFound（E04）', () {
      expect(
        () => parser.parseBody(<String, dynamic>{
          'code': 404,
          'tweet': null,
        }, tweetId: '1790637656616943991'),
        throwsA(isA<TweetNotFound>()),
      );
    });

    test('code=429 → RateLimited（E03）', () {
      expect(
        () => parser.parseBody(<String, dynamic>{
          'code': 429,
          'tweet': null,
        }, tweetId: '1790637656616943991'),
        throwsA(isA<RateLimited>()),
      );
    });

    test('media 无 videos → NotVideoTweet（E05）', () {
      expect(
        () => parser.parseBody(<String, dynamic>{
          'code': 200,
          'tweet': <String, dynamic>{
            'id': '1790637656616943991',
            'text': 'photo tweet',
            'author': <String, dynamic>{'name': 'A', 'screen_name': 'a'},
            'media': <String, dynamic>{
              'photos': <dynamic>[
                <String, dynamic>{'url': 'https://pbs.twimg.com/media/x.jpg'},
              ],
            },
          },
        }, tweetId: '1790637656616943991'),
        throwsA(isA<NotVideoTweet>()),
      );
    });

    test('sensitive → RestrictedContent（E06，NSFW 双保险）', () {
      expect(
        () => parser.parseBody(<String, dynamic>{
          'code': 200,
          'tweet': <String, dynamic>{
            'id': '1790637656616943991',
            'sensitive': true,
            'author': <String, dynamic>{'name': 'A', 'screen_name': 'a'},
            'media': <String, dynamic>{
              'videos': <dynamic>[
                <String, dynamic>{'url': 'https://video.twimg.com/a.mp4', 'duration': 1.0},
              ],
            },
          },
        }, tweetId: '1790637656616943991'),
        throwsA(isA<RestrictedContent>()),
      );
    });

    test('tweet 结构缺失 → EndpointDrift（E07）', () {
      expect(
        () => parser.parseBody(<String, dynamic>{'code': 200}, tweetId: '1790637656616943991'),
        throwsA(isA<EndpointDrift>()),
      );
    });
  });

  group('防御式字段读取：类型突变按字段缺失，绝不抛 TypeError/UnsupportedError', () {
    /// 形态 B（formats[] 多码率）可覆写构造基线。
    Map<String, dynamic> fxBody({
      Object? duration = 20.5,
      Object? id = '1790637656616943991',
      Object? code = 200,
      Map<String, Object?> formatEntry = const <String, Object?>{},
      Map<String, Object?> authorEntry = const <String, Object?>{},
      Map<String, Object?> videoEntry = const <String, Object?>{},
      Map<String, Object?> tweetEntry = const <String, Object?>{},
    }) =>
        <String, dynamic>{
          'code': code,
          'tweet': <String, dynamic>{
            'id': id,
            'text': 'defensive form',
            'created_at': 'Sat Jun 08 14:22:31 +0000 2024',
            'author': <String, dynamic>{
              'name': 'Historic Vids',
              'screen_name': 'historyinmemes',
              'avatar_url': 'https://pbs.twimg.com/profile_images/1/a_200x200.jpg',
              ...authorEntry,
            },
            'media': <String, dynamic>{
              'videos': <dynamic>[
                <String, dynamic>{
                  'duration': duration,
                  'thumbnail_url': 'https://pbs.twimg.com/ext_tw_video_thumb/1/img.jpg',
                  'formats': <dynamic>[
                    <String, Object?>{
                      'container': 'mp4',
                      'bitrate': 2176000,
                      'url': 'https://video.twimg.com/amplify_video/1/vid/avc1/728x720/a.mp4?tag=14',
                      ...formatEntry,
                    },
                  ],
                  ...videoEntry,
                },
              ],
            },
            ...tweetEntry,
          },
        };

    test('duration 为字符串 → 按缺失处理（0），不抛 TypeError', () {
      final result = parser.parseBody(fxBody(duration: '20.5'), tweetId: '1790637656616943991');
      expect(result.tweet.durationMillis, 0);
      expect(result.tweet.variants.single.estimatedBytes, 0);
    });

    test('duration 超大值（1e306）/ Infinity → 钳制 int64 安全域，round 不抛不回绕', () {
      for (final duration in [1e306, double.infinity]) {
        final result = parser.parseBody(fxBody(duration: duration), tweetId: '1790637656616943991');
        expect(result.tweet.durationMillis, greaterThan(0), reason: 'duration=$duration');
        expect(result.tweet.durationMillis, lessThanOrEqualTo(9223372036854775807), reason: 'duration=$duration');
        expect(result.tweet.variants.single.estimatedBytes, greaterThan(0), reason: 'duration=$duration');
      }
    });

    test('duration 为负数 → 按缺失处理（0）', () {
      final result = parser.parseBody(fxBody(duration: -3.5), tweetId: '1790637656616943991');
      expect(result.tweet.durationMillis, 0);
    });

    test('code 为字符串 → 按字段缺失跳过 code 映射，继续结构判定', () {
      final result = parser.parseBody(fxBody(code: '200'), tweetId: '1790637656616943991');
      expect(result.tweet.variants.single.bitrate, 2176000);
    });

    test('tweet.id 为数字 → 回落入参 tweetId，不抛 TypeError', () {
      final result = parser.parseBody(fxBody(id: 1790637656616943991), tweetId: '1790637656616943991');
      expect(result.tweet.tweetId, '1790637656616943991');
    });

    test('formats 内 url 数字 / container 数字 → 突变条目被过滤 → NotVideoTweet', () {
      expect(
        () => parser.parseBody(
          fxBody(formatEntry: <String, Object?>{'container': 123, 'url': 456}),
          tweetId: '1790637656616943991',
        ),
        throwsA(isA<NotVideoTweet>()),
      );
    });

    test('videos 含 null 条目与 formats 全 null 条目 → 跳过后无合法变体 → NotVideoTweet', () {
      expect(
        () => parser.parseBody(
          <String, dynamic>{
            'code': 200,
            'tweet': <String, dynamic>{
              'id': '1790637656616943991',
              'text': 'null entries',
              'author': <String, dynamic>{'name': 'A', 'screen_name': 'a'},
              'media': <String, dynamic>{
                'videos': <dynamic>[
                  null, // videos 条目本身为 null：whereType 跳过
                  <String, dynamic>{
                    'duration': 1.5,
                    'formats': <dynamic>[null], // 全部突变/空条目 → 无合法变体
                  },
                ],
              },
            },
          },
          tweetId: '1790637656616943991',
        ),
        throwsA(isA<NotVideoTweet>()),
      );
    });

    test('formats 混合 null 与合法条目 → 仅保留合法条目', () {
      final result = parser.parseBody(
        fxBody(
          videoEntry: <String, Object?>{
            'formats': <dynamic>[
              null,
              <String, Object?>{
                'container': 'mp4',
                'bitrate': 832000,
                'url': 'https://video.twimg.com/amplify_video/1/vid/avc1/364x360/b.mp4?tag=14',
              },
            ],
          },
        ),
        tweetId: '1790637656616943991',
      );
      expect(result.tweet.variants, hasLength(1));
      expect(result.tweet.variants.single.bitrate, 832000);
    });

    test('author/avatar/name 类型突变 → 空串兜底，不抛 TypeError', () {
      final result = parser.parseBody(
        fxBody(
          authorEntry: <String, Object?>{'name': 42, 'screen_name': true, 'avatar_url': 999},
        ),
        tweetId: '1790637656616943991',
      );
      expect(result.tweet.userName, '');
      expect(result.tweet.screenName, '');
      expect(result.tweet.avatarUrl, '');
    });

    test('thumbnail 类型突变 → 回落 photos[0].url；photos[0].url 也突变 → 空串', () {
      final withPhotos = <String, dynamic>{
        'code': 200,
        'tweet': <String, dynamic>{
          'id': '1790637656616943991',
          'text': 'photo fallback',
          'author': <String, dynamic>{'name': 'A', 'screen_name': 'a'},
          'media': <String, dynamic>{
            'photos': <dynamic>[
              <String, dynamic>{'url': 'https://pbs.twimg.com/media/x.jpg'},
            ],
            'videos': <dynamic>[
              <String, dynamic>{
                'duration': 2.0,
                'thumbnail_url': 123, // 类型突变 → 回落 photos
                'url': 'https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/1280x720/a.mp4?tag=12',
              },
            ],
          },
        },
      };
      final result = parser.parseBody(withPhotos, tweetId: '1790637656616943991');
      expect(result.tweet.thumbnailUrl, 'https://pbs.twimg.com/media/x.jpg');

      final brokenPhotos = <String, dynamic>{
        'code': 200,
        'tweet': <String, dynamic>{
          'id': '1790637656616943991',
          'text': 'broken photos',
          'author': <String, dynamic>{'name': 'A', 'screen_name': 'a'},
          'media': <String, dynamic>{
            'photos': <dynamic>[
              <String, dynamic>{'url': 123}, // 回落源也类型突变 → 空串
            ],
            'videos': <dynamic>[
              <String, dynamic>{
                'duration': 2.0,
                'thumbnail_url': 123,
                'url': 'https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/1280x720/a.mp4?tag=12',
              },
            ],
          },
        },
      };
      expect(parser.parseBody(brokenPhotos, tweetId: '1790637656616943991').tweet.thumbnailUrl, '');
    });

    test('width/height 为字符串 → 按缺失处理（不回落条目分辨率）', () {
      final result = parser.parseBody(
        fxBody(
          formatEntry: <String, Object?>{
            // URL 无 /vid/WxH/ 路径 → 依赖条目 width/height 回落。
            'url': 'https://video.twimg.com/ext_tw_video/1/pu/vid/nores/a.mp4?tag=12',
          },
          videoEntry: <String, Object?>{'width': '1280', 'height': '720'},
        ),
        tweetId: '1790637656616943991',
      );
      expect(result.tweet.variants.single.width, isNull);
      expect(result.tweet.variants.single.height, isNull);
    });

    test('created_timestamp 超大值 / 字符串 → 跳过回落 created_at，不抛 RangeError', () {
      for (final createdTimestamp in [9223372036854775807, '1715756260']) {
        final result = parser.parseBody(
          fxBody(tweetEntry: <String, Object?>{'created_timestamp': createdTimestamp}),
          tweetId: '1790637656616943991',
        );
        // created_at 为 Twitter 英文格式（2024-06-08T14:22:31Z）。
        expect(result.tweet.createdAt, DateTime.utc(2024, 6, 8, 14, 22, 31), reason: 'created_timestamp=$createdTimestamp');
      }
    });
  });

  group('resolve() HTTP 状态映射（本地 stub dio）', () {
    Future<FxTwitterParser> parserWith(Iterable<StubResponse> responses) async {
      final dio = Dio()..httpClientAdapter = StubAdapter(responses);
      return FxTwitterParser(dio: dio, config: EndpointConfig.builtIn());
    }

    test('404 → TweetNotFound', () async {
      final p = await parserWith([const StubResponse(404, '{"code":404}')]);
      await expectLater(p.resolve('1790637656616943991'), throwsA(isA<TweetNotFound>()));
    });

    test('429 → RateLimited', () async {
      final p = await parserWith([const StubResponse(429, '{"code":429}')]);
      await expectLater(p.resolve('1790637656616943991'), throwsA(isA<RateLimited>()));
    });

    test('500 → NetworkTimeout', () async {
      final p = await parserWith([const StubResponse(500, 'oops')]);
      await expectLater(p.resolve('1790637656616943991'), throwsA(isA<NetworkTimeout>()));
    });

    test('200 真实夹具 → 成功', () async {
      final p = await parserWith([StubResponse(200, readFixture('fxtwitter_status_ok.json'))]);
      final result = await p.resolve('1790637656616943991');
      expect(result.parserVersion, kFxTwitterParserVersion);
      expect(result.tweet.variants.first.bitrate, 2176000);
    });
  });
}
