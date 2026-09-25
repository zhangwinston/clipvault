/// Syndication 端点 HTTP 客户端（DESIGN §6.1）。
///
/// 职责：dio 单次 GET（6s 接收超时、普通浏览器 UA、lang 回落、
/// 全状态码放行交由 Parser 分类）。不做任何 JSON 语义判定——
/// 七类错误分类是 Parser 的职责（§6.3/§6.6）。
///
/// dio 经构造注入以便测试 mock（DESIGN §9-2）。
library;

import 'package:dio/dio.dart';

import 'endpoint_config.dart';

/// 一次 syndication 端点响应的原始快照（状态码 + content-type + 文本体）。
///
/// 保留原文（ResponseType.plain）的原因：
/// - 空响应体 `{}` 需要原样特判（§6.3 → TweetNotFound）；
/// - 404 dogpage 是 HTML 而非 JSON，提前 jsonDecode 会崩溃。
class SyndicationResponse {
  const SyndicationResponse({
    required this.statusCode,
    required this.contentType,
    required this.body,
  });

  final int statusCode;
  final String contentType;
  final String body;

  /// content-type 含 html（dogpage 判定，§6.1）。
  bool get isHtml => contentType.toLowerCase().contains('html');
}

/// syndication tweet-result 端点客户端。
class SyndicationClient {
  SyndicationClient({required this._dio});

  final Dio _dio;

  /// 单次 GET（无 lang 回落）。模板占位符：{id} {token} {lang}。
  Future<SyndicationResponse> fetchTweetResult({
    required String tweetId,
    required String token,
    required EndpointConfig config,
    String lang = 'en',
  }) async {
    final url = config.primary.urlTemplate
        .replaceAll('{id}', tweetId)
        .replaceAll('{token}', token)
        .replaceAll('{lang}', lang);
    final response = await _dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        // 全状态码放行：404/429/403 等由 Parser 分类（§6.6）。
        validateStatus: (_) => true,
        headers: <String, String>{
          'User-Agent': config.primary.ua,
          'Accept': 'application/json',
        },
        connectTimeout: Duration(milliseconds: config.primary.timeoutMs),
        receiveTimeout: Duration(milliseconds: config.primary.timeoutMs),
      ),
    );
    return SyndicationResponse(
      statusCode: response.statusCode ?? 0,
      contentType: response.headers.value('content-type') ?? '',
      body: response.data ?? '',
    );
  }

  /// 带 lang 回落的获取（§6.1「lang=zh-CN 失败回落 en」）。
  ///
  /// 回落条件：仅当响应为「与语言相关的 4xx」——即 400~499 且排除
  /// 404（TweetNotFound）、403/429（RateLimited）这些已有明确分类的状态码。
  /// 网络层异常（超时/DNS/连接）不触发 lang 回落——那是 E02 退避重试的职责（§6.5）。
  Future<SyndicationResponse> fetchWithLangFallback({
    required String tweetId,
    required String token,
    required EndpointConfig config,
    List<String> langs = const ['zh-CN', 'en'],
  }) async {
    SyndicationResponse? last;
    for (final lang in langs) {
      final resp = await fetchTweetResult(
        tweetId: tweetId,
        token: token,
        config: config,
        lang: lang,
      );
      last = resp;
      if (!_langRetryable(resp.statusCode)) return resp;
    }
    return last!;
  }

  bool _langRetryable(int status) =>
      status >= 400 && status < 500 && status != 404 && status != 403 && status != 429;
}
