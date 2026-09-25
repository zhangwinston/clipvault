/// SyndicationParser 七夹具回放与错误分类测试（DESIGN §11.1）。
///
/// 覆盖：video_ok / multi_video / photo_only（→E05）/ 404 dogpage（→E04）/
/// 空{}（→E04）/ sensitive（→E06）/ 结构缺失（→E07 守卫）；
/// 以及 variants 降序、分辨率 URL 提取、estBytes、多视频遍历、
/// HTTP 状态码映射与 lang 回落（本地 mock，零真实网络）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/core/error.dart';
import 'package:clipvault/parse/endpoint_config.dart';
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/parse/syndication_client.dart';
import 'package:clipvault/parse/syndication_parser.dart';

/// 读取 assets/fixtures 下的夹具（flutter test CWD = 工程根）。
String readFixture(String name) {
  final file = File('assets/fixtures/$name');
  if (!file.existsSync()) {
    fail('夹具缺失：assets/fixtures/$name（S1 负责生成）');
  }
  return file.readAsStringSync();
}

SyndicationResponse okJson(String body) => SyndicationResponse(
      statusCode: 200,
      contentType: 'application/json; charset=utf-8',
      body: body,
    );

/// 本地 stub HTTP 适配器（dio HttpClientAdapter mock，零真实网络）。
class StubResponse {
  const StubResponse(this.status, this.body, {this.contentType});
  final int status;
  final String body;
  final String? contentType;
}

class StubAdapter implements HttpClientAdapter {
  StubAdapter(Iterable<StubResponse> responses, {this.errorToThrow})
      : _queue = List.of(responses);

  final List<StubResponse> _queue;
  final Object? errorToThrow;
  final List<Uri> requestedUris = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedUris.add(options.uri);
    if (errorToThrow != null) {
      throw errorToThrow!;
    }
    expect(_queue, isNotEmpty, reason: 'stub 响应队列已耗尽');
    final stub = _queue.removeAt(0);
    final bytes = Uint8List.fromList(utf8.encode(stub.body));
    // dio 5.x 移除了 ResponseBody.fromUint8List；真实构造为 stream+statusCode，
    // fromBytes 即其便捷形态（内部 Stream.value 单块字节流）。
    return ResponseBody.fromBytes(
      bytes,
      stub.status,
      headers: <String, List<String>>{
        'content-type': [stub.contentType ?? 'application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

SyndicationParser buildParser() => SyndicationParser(
      client: SyndicationClient(dio: Dio()),
      config: EndpointConfig.builtIn(),
      langs: const ['en'],
    );

void main() {
  final parser = buildParser();

  group('夹具回放：syndication_video_ok（单视频全 variants）', () {
    test('解析成功且字段映射完整', () {
      final result =
          parser.parseResponse(okJson(readFixture('syndication_video_ok.json')), tweetId: '1790637656616943991');

      expect(result.parserVersion, kSyndicationParserVersion);
      final tweet = result.tweet;
      expect(tweet.tweetId, '1790637656616943991');
      expect(tweet.userName, 'Historic Vids');
      expect(tweet.screenName, 'historyinmemes');
      expect(tweet.avatarUrl, contains('pbs.twimg.com/profile_images'));
      expect(tweet.text, startsWith('One of the most intense moments'));
      expect(tweet.createdAt, DateTime.parse('2024-05-15T06:57:40.000Z'));
      expect(
        tweet.thumbnailUrl,
        'https://pbs.twimg.com/amplify_video_thumb/1790637589910654976/img/jyhLQQZkq-lJJ9fN.jpg',
      );
      expect(tweet.durationMillis, 15488);
      expect(tweet.possiblySensitive, isFalse);
      expect(tweet.videoCount, 1);
    });

    test('variants 仅 mp4、bitrate>0、按码率降序；分辨率从 URL 提取；estBytes 换算', () {
      final result =
          parser.parseResponse(okJson(readFixture('syndication_video_ok.json')), tweetId: '1790637656616943991');
      final variants = result.tweet.variants;

      expect(variants.length, 3); // HLS 变体不暴露（§12.9）
      expect(variants.map((v) => v.bitrate), [2176000, 832000, 288000]);
      expect(variants.every((v) => v.contentType == VariantContentType.mp4), isTrue);

      final top = variants.first;
      expect(top.url, contains('/vid/avc1/728x720/'));
      expect(top.width, 728);
      expect(top.height, 720);
      // estBytes = bitrate × durationMillis / 8000（bit→byte、ms→s）。
      expect(top.estimatedBytes, 2176000 * 15488 ~/ 8000);
      expect(top.estimatedBytes, 4212736);
      expect(top.qualityLabel, '720p (HD)');
    });

    test('低分辨率档位标签按高度分桶（272x270 → 360p）', () {
      final result =
          parser.parseResponse(okJson(readFixture('syndication_video_ok.json')), tweetId: '1790637656616943991');
      final lowest = result.tweet.variants.last;
      expect(lowest.height, 270);
      expect(lowest.qualityLabel, '360p');
    });
  });

  group('夹具回放：syndication_multi_video（多视频遍历）', () {
    test('默认选中第 1 个视频', () {
      final result = parser.parseResponse(
        okJson(readFixture('syndication_multi_video.json')),
        tweetId: '1798765432109876543',
      );
      expect(result.tweet.videoCount, 2);
      expect(result.tweet.durationMillis, 26380);
      expect(result.tweet.thumbnailUrl, contains('AbCdEfGhIjKlMnOp'));
      expect(result.tweet.variants.first.bitrate, 2176000);
    });

    test('videoIndex=1 选中第 2 个视频（duration/变体独立）', () {
      final result = parser.parseResponse(
        okJson(readFixture('syndication_multi_video.json')),
        tweetId: '1798765432109876543',
        videoIndex: 1,
      );
      expect(result.tweet.videoCount, 2);
      expect(result.tweet.durationMillis, 18420);
      expect(result.tweet.thumbnailUrl, contains('ZxWvUtSrQpOnMlKj'));
      expect(result.tweet.variants.first.bitrate, 1276800);
      expect(result.tweet.variants.first.width, 1280);
      expect(result.tweet.variants.first.height, 720);
    });
  });

  test('夹具回放：syndication_photo_only → NotVideoTweet（E05）', () {
    expect(
      () => parser.parseResponse(
        okJson(readFixture('syndication_photo_only.json')),
        tweetId: '1791234567890123456',
      ),
      throwsA(isA<NotVideoTweet>()),
    );
  });

  group('纯文本推文：mediaDetails 缺失 → E05（error_codes.md 实现注记）', () {
    test('mediaDetails 键整体不存在 → NotVideoTweet（不得误报 E07）', () {
      final body = jsonEncode(<String, dynamic>{
        '__typename': 'Tweet',
        'id_str': '20',
        'text': '纯文本推文，无任何媒体附件',
        'created_at': '2024-05-15T06:57:40.000Z',
        'user': <String, dynamic>{
          'name': 'Text Only',
          'screen_name': 'textonly',
          'profile_image_url_https': 'https://pbs.twimg.com/profile_images/1/a_normal.jpg',
        },
      });
      expect(
        () => parser.parseResponse(okJson(body), tweetId: '20'),
        throwsA(isA<NotVideoTweet>()),
      );
    });

    test('mediaDetails 为 null / 空数组 / 类型突变（字符串）→ 统一 NotVideoTweet', () {
      for (final mediaDetails in [null, <dynamic>[], 'oops', <String, dynamic>{}]) {
        final body = jsonEncode(<String, dynamic>{
          '__typename': 'Tweet',
          'user': <String, dynamic>{'screen_name': 'a'},
          'mediaDetails': mediaDetails,
        });
        expect(
          () => parser.parseResponse(okJson(body), tweetId: '20'),
          throwsA(isA<NotVideoTweet>()),
          reason: 'mediaDetails=$mediaDetails 三形态统一归 E05',
        );
      }
    });

    test('出厂守卫不含 mediaDetails（user.screen_name 仍是 E07 守卫项）', () {
      expect(
        EndpointConfig.builtIn().driftGuard.requiredFields,
        ['user.screen_name'],
      );
    });
  });

  test('夹具回放：syndication_empty（200 + 空 {}）→ TweetNotFound（E04）', () {
    expect(
      () => parser.parseResponse(okJson(readFixture('syndication_empty.json')), tweetId: '1790637656616943991'),
      throwsA(isA<TweetNotFound>()),
    );
  });

  test('夹具回放：syndication_sensitive → RestrictedContent（E06）', () {
    expect(
      () => parser.parseResponse(
        okJson(readFixture('syndication_sensitive.json')),
        tweetId: '1789012345678901234',
      ),
      throwsA(isA<RestrictedContent>()),
    );
  });

  test('夹具回放：syndication_404_dogpage（HTML）→ TweetNotFound（E04）', () {
    final dogpage = readFixture('syndication_404_dogpage.html');
    expect(
      () => parser.parseResponse(
        SyndicationResponse(statusCode: 404, contentType: 'text/html; charset=utf-8', body: dogpage),
        tweetId: '1790637656616943991',
      ),
      throwsA(isA<TweetNotFound>()),
    );
    // 200 + HTML 同样按 dogpage 归 E04（防御：错误页可能伴随非 404 状态码）。
    expect(
      () => parser.parseResponse(
        SyndicationResponse(statusCode: 200, contentType: 'text/html', body: dogpage),
        tweetId: '1790637656616943991',
      ),
      throwsA(isA<TweetNotFound>()),
    );
  });

  group('HTML 错误页三态：状态码分类优先于 isHtml（403/429/200）', () {
    final dogpage = readFixture('syndication_404_dogpage.html');

    test('403 + HTML 风控挑战页 → RateLimited（E03，备源切换语义不得被 E04 掩盖）', () {
      expect(
        () => parser.parseResponse(
          SyndicationResponse(statusCode: 403, contentType: 'text/html; charset=utf-8', body: dogpage),
          tweetId: '1790637656616943991',
        ),
        throwsA(isA<RateLimited>()),
      );
    });

    test('429 + HTML 限频页 → RateLimited（E03）', () {
      expect(
        () => parser.parseResponse(
          SyndicationResponse(statusCode: 429, contentType: 'text/html', body: dogpage),
          tweetId: '1790637656616943991',
        ),
        throwsA(isA<RateLimited>()),
      );
    });

    test('503 + HTML 错误页 → NetworkTimeout（E02，可重试）', () {
      expect(
        () => parser.parseResponse(
          SyndicationResponse(statusCode: 503, contentType: 'text/html', body: dogpage),
          tweetId: '1790637656616943991',
        ),
        throwsA(isA<NetworkTimeout>()),
      );
    });

    test('200 + HTML → TweetNotFound（E04，dogpage 伴随 200 的既有形态）', () {
      expect(
        () => parser.parseResponse(
          SyndicationResponse(statusCode: 200, contentType: 'text/html', body: dogpage),
          tweetId: '1790637656616943991',
        ),
        throwsA(isA<TweetNotFound>()),
      );
    });
  });

  group('EndpointDrift 守卫（E07）', () {
    test('__typename != Tweet → EndpointDrift', () {
      final body = jsonEncode(<String, dynamic>{
        '__typename': 'TweetWithVisibilityResults',
        'user': <String, dynamic>{'screen_name': 'a'},
        'mediaDetails': <dynamic>[],
      });
      expect(
        () => parser.parseResponse(okJson(body), tweetId: '1790637656616943991'),
        throwsA(isA<EndpointDrift>()),
      );
    });

    test('关键字段缺失（user.screen_name 不存在）→ EndpointDrift', () {
      final body = jsonEncode(<String, dynamic>{
        '__typename': 'Tweet',
        'user': <String, dynamic>{'name': 'Only Name'},
        'mediaDetails': <dynamic>[],
      });
      expect(
        () => parser.parseResponse(okJson(body), tweetId: '1790637656616943991'),
        throwsA(isA<EndpointDrift>()),
      );
    });

    test('200 但 body 非 JSON → EndpointDrift', () {
      expect(
        () => parser.parseResponse(
          SyndicationResponse(statusCode: 200, contentType: 'application/json', body: '<html>oops</html>'),
          tweetId: '1790637656616943991',
        ),
        throwsA(isA<EndpointDrift>()),
      );
    });
  });

  group('防御式字段读取：类型突变按字段缺失，绝不抛 TypeError', () {
    /// 最小合法视频推文体（可覆写 video_info / 根级 / user 字段的构造基线）。
    Map<String, dynamic> videoTweetBody(
      Map<String, Object?> videoInfoOverrides, {
      Map<String, Object?> rootOverrides = const <String, Object?>{},
      Map<String, Object?> userOverrides = const <String, Object?>{},
    }) =>
        <String, dynamic>{
          '__typename': 'Tweet',
          'id_str': '1790637656616943991',
          'text': 'video tweet',
          'created_at': '2024-05-15T06:57:40.000Z',
          'user': <String, dynamic>{
            'name': 'Historic Vids',
            'screen_name': 'historyinmemes',
            'profile_image_url_https': 'https://pbs.twimg.com/profile_images/1/a_normal.jpg',
            ...userOverrides,
          },
          'mediaDetails': <dynamic>[
            <String, dynamic>{
              'type': 'video',
              'media_url_https': 'https://pbs.twimg.com/amplify_video_thumb/1/img/a.jpg',
              'video_info': <String, dynamic>{
                'duration_millis': 15488,
                'variants': <dynamic>[
                  <String, Object?>{
                    'bitrate': 2176000,
                    'content_type': 'video/mp4',
                    'url': 'https://video.twimg.com/amplify_video/1/vid/avc1/728x720/a.mp4?tag=14',
                  },
                ],
                ...videoInfoOverrides,
              },
            },
          ],
          ...rootOverrides,
        };

    test('duration_millis 为字符串 → 按缺失处理（0），不抛 TypeError', () {
      final result = parser.parseResponse(
        okJson(jsonEncode(videoTweetBody(<String, Object?>{'duration_millis': '63000'}))),
        tweetId: '1790637656616943991',
      );
      expect(result.tweet.durationMillis, 0);
      expect(result.tweet.variants.single.estimatedBytes, 0);
    });

    test('duration_millis 为 Infinity（JSON 1e999）→ 按缺失处理（0）', () {
      // jsonEncode 无法序列化 Infinity，直接使用原始 JSON 文本。
      const body =
          '{"__typename":"Tweet","user":{"screen_name":"a"},"mediaDetails":[{"type":"video",'
          '"video_info":{"duration_millis":1e999,"variants":[{"bitrate":2176000,'
          '"content_type":"video/mp4","url":"https://video.twimg.com/a.mp4"}]}}]}';
      final result = parser.parseResponse(okJson(body), tweetId: '1790637656616943991');
      expect(result.tweet.durationMillis, 0);
    });

    test('duration_millis 为 int64 上限 → 保留原值且 estimatedBytes 钳制非负', () {
      final result = parser.parseResponse(
        okJson(jsonEncode(videoTweetBody(<String, Object?>{'duration_millis': 9223372036854775807}))),
        tweetId: '1790637656616943991',
      );
      expect(result.tweet.durationMillis, 9223372036854775807);
      expect(result.tweet.variants.single.estimatedBytes, greaterThan(0));
    });

    test('bitrate 全部突变为字符串 → 变体按缺失过滤 → NotVideoTweet（E05）', () {
      expect(
        () => parser.parseResponse(
          okJson(jsonEncode(videoTweetBody(<String, Object?>{
            'variants': <dynamic>[
              <String, Object?>{
                'bitrate': '2176000',
                'content_type': 'video/mp4',
                'url': 'https://video.twimg.com/amplify_video/1/vid/avc1/728x720/a.mp4?tag=14',
              },
            ],
          }))),
          tweetId: '1790637656616943991',
        ),
        throwsA(isA<NotVideoTweet>()),
      );
    });

    test('variants 含 null 条目与 url 数字条目 → 跳过突变条目保留合法条目', () {
      final result = parser.parseResponse(
        okJson(jsonEncode(videoTweetBody(<String, Object?>{
          'variants': <dynamic>[
            null,
            <String, Object?>{'bitrate': 832000, 'content_type': 'video/mp4', 'url': 123},
            <String, Object?>{
              'bitrate': 288000,
              'content_type': 'video/mp4',
              'url': 'https://video.twimg.com/amplify_video/1/vid/avc1/364x360/b.mp4?tag=14',
            },
          ],
        }))),
        tweetId: '1790637656616943991',
      );
      expect(result.tweet.variants, hasLength(1));
      expect(result.tweet.variants.single.bitrate, 288000);
    });

    test('id_str / user 字段类型突变 → 按缺失回落默认值，不抛 TypeError', () {
      final result = parser.parseResponse(
        okJson(jsonEncode(videoTweetBody(
          <String, Object?>{},
          rootOverrides: <String, Object?>{'id_str': 1790637656616943991, 'created_at': 12345},
          userOverrides: <String, Object?>{
            'name': 42,
            'screen_name': true, // 守卫按非 null 通过，映射层按类型突变回落 ''
            'profile_image_url_https': null,
          },
        ))),
        tweetId: '1790637656616943991',
      );
      expect(result.tweet.tweetId, '1790637656616943991'); // 回落入参 ID
      expect(result.tweet.userName, '');
      expect(result.tweet.screenName, '');
      expect(result.tweet.avatarUrl, '');
      expect(result.tweet.createdAt, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('note_tweet.text 与 text 均类型突变 → 空串兜底', () {
      final result = parser.parseResponse(
        okJson(jsonEncode(videoTweetBody(
          <String, Object?>{},
          rootOverrides: <String, Object?>{
            'text': 999,
            'note_tweet': <String, dynamic>{'text': false},
          },
        ))),
        tweetId: '1790637656616943991',
      );
      expect(result.tweet.text, '');
    });
  });

  group('HTTP 状态码分类（§6.6）', () {
    test('403 / 429 → RateLimited（403 不归锁推）', () {
      for (final status in [403, 429]) {
        expect(
          () => parser.parseResponse(
            SyndicationResponse(statusCode: status, contentType: 'application/json', body: ''),
            tweetId: '1790637656616943991',
          ),
          throwsA(isA<RateLimited>()),
          reason: 'status=$status',
        );
      }
    });

    test('5xx → NetworkTimeout', () {
      expect(
        () => parser.parseResponse(
          SyndicationResponse(statusCode: 503, contentType: 'application/json', body: ''),
          tweetId: '1790637656616943991',
        ),
        throwsA(isA<NetworkTimeout>()),
      );
    });

    test('其余 4xx → EndpointDrift', () {
      expect(
        () => parser.parseResponse(
          SyndicationResponse(statusCode: 400, contentType: 'application/json', body: ''),
          tweetId: '1790637656616943991',
        ),
        throwsA(isA<EndpointDrift>()),
      );
    });
  });

  group('resolve() HTTP 集成（本地 stub dio，零真实网络）', () {
    test('200 真实夹具体 → 成功；请求 URL 携带 id 与 token', () async {
      final adapter = StubAdapter([
        StubResponse(200, readFixture('syndication_video_ok.json')),
      ]);
      final dio = Dio()..httpClientAdapter = adapter;
      final p = SyndicationParser(
        client: SyndicationClient(dio: dio),
        config: EndpointConfig.builtIn(),
        langs: const ['en'],
      );

      final result = await p.resolve('1790637656616943991');

      expect(result.tweet.variants.first.bitrate, 2176000);
      expect(adapter.requestedUris, hasLength(1));
      final query = adapter.requestedUris.first.queryParameters;
      expect(query['id'], '1790637656616943991');
      expect(query['token'], isNotEmpty); // token 算法本身由 core/token_test 穷举验证
      expect(query['lang'], 'en');
    });

    test('dogpage 404 → TweetNotFound', () async {
      final adapter = StubAdapter([
        StubResponse(404, readFixture('syndication_404_dogpage.html'), contentType: 'text/html; charset=utf-8'),
      ]);
      final dio = Dio()..httpClientAdapter = adapter;
      final p = SyndicationParser(
        client: SyndicationClient(dio: dio),
        config: EndpointConfig.builtIn(),
        langs: const ['en'],
      );
      await expectLater(
        p.resolve('1790637656616943991'),
        throwsA(isA<TweetNotFound>()),
      );
    });

    test('网络层异常 → NetworkTimeout（E02）', () async {
      final adapter = StubAdapter(
        [],
        errorToThrow: DioException(
          type: DioExceptionType.connectionTimeout,
          requestOptions: RequestOptions(path: 'https://cdn.syndication.twimg.com/tweet-result'),
        ),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final p = SyndicationParser(
        client: SyndicationClient(dio: dio),
        config: EndpointConfig.builtIn(),
        langs: const ['en'],
      );
      await expectLater(
        p.resolve('1790637656616943991'),
        throwsA(isA<NetworkTimeout>()),
      );
    });

    test('lang 回落：zh-CN 400 后回落 en 200（§6.1）', () async {
      final adapter = StubAdapter([
        const StubResponse(400, '{"error":"lang"}'),
        StubResponse(200, readFixture('syndication_video_ok.json')),
      ]);
      final dio = Dio()..httpClientAdapter = adapter;
      final p = SyndicationParser(
        client: SyndicationClient(dio: dio),
        config: EndpointConfig.builtIn(),
        langs: const ['zh-CN', 'en'],
      );

      final result = await p.resolve('1790637656616943991');

      expect(result.tweet.videoCount, 1);
      expect(adapter.requestedUris, hasLength(2));
      expect(adapter.requestedUris[0].queryParameters['lang'], 'zh-CN');
      expect(adapter.requestedUris[1].queryParameters['lang'], 'en');
    });

    test('lang 不回落：429 直接按 RateLimited 透出（单请求）', () async {
      final adapter = StubAdapter([const StubResponse(429, '{"error":"rate"}')]);
      final dio = Dio()..httpClientAdapter = adapter;
      final p = SyndicationParser(
        client: SyndicationClient(dio: dio),
        config: EndpointConfig.builtIn(),
        langs: const ['zh-CN', 'en'],
      );
      await expectLater(p.resolve('1790637656616943991'), throwsA(isA<RateLimited>()));
      expect(adapter.requestedUris, hasLength(1));
    });
  });
}
