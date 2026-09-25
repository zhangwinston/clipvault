// bin/smoke.dart —— 宿主机 E2E 真端点冒烟脚本（DESIGN §11.3 / §10 Milestone 1 判据）
//
// 本脚本不进入 flutter test（测试必须离线），由人工在宿主机执行：
//   dart run bin/smoke.dart [推文ID 或 x.com/twitter.com 推文URL]
//   无参数时使用 DESIGN §6.2 已知向量推文 1790637656616943991。
//
// 验证链路（Milestone 1 判据「解析 200 + Range 下载前 64KB 校验」）：
//   1) 推文 ID 提取（容忍裸 ID 或状态页 URL）；
//   2) 调用与 App 同源的 lib/core/token.dart#getToken 计算 syndication token，
//      默认向量时额外硬断言 token == '4c9gcitu1vq'（评委复现值，§6.2）；
//   3) GET cdn.syndication.twimg.com/tweet-result（普通浏览器 UA，不伪装
//      Googlebot），断言 HTTP 200 + JSON 对象 + 非空 {}（§6.1/§6.3 特判）；
//   4) 遍历 mediaDetails，收集 content_type==video/mp4 且 bitrate>0 的变体，
//      选最高码率档（HLS 不暴露，§12.9）；
//   5) 对直链发 Range: bytes=0-65535，断言 206（200 记警告：范围被忽略），
//      前 64KB 落盘到系统临时目录，校验字节数与 MP4 ftyp 魔数（软校验）。
//
// 退出码：0 = 通过；1 = 失败（参数错误 / 网络异常 / 结构漂移 / 校验不过）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipvault/core/token.dart';

/// 主源端点模板（与 assets/config/endpoints.json v1 保持一致；冒烟脚本内联
/// 常量，不耦合资产加载逻辑——DESIGN §6.1/§6.7）。
const String _kEndpointTemplate =
    'https://cdn.syndication.twimg.com/tweet-result?id={id}&lang=en&token={token}';

/// 普通浏览器 UA（DESIGN §6.1：评委实测默认 UA + 正确 token 即 200，
/// 明确不采用 Googlebot 伪装——规避清单 §1.4）。
const String _kUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';

/// DESIGN §6.2 已知向量（评委复现值）。
const String _kDefaultTweetId = '1790637656616943991';
const String _kExpectedToken = '4c9gcitu1vq';

/// Range 取样大小：前 64KB（DESIGN §11.3）。
const int _kRangeBytes = 64 * 1024;

/// 冒烟超时（App 内为 6s，DESIGN §6.1；冒烟放宽到 10s 以容忍弱网抖动）。
const Duration _kTimeout = Duration(seconds: 10);

void _info(String message) => stdout.writeln('[INFO] $message');
void _warn(String message) => stdout.writeln('[WARN] $message');
void _err(String message) => stderr.writeln('[FAIL] $message');

Future<int> main(List<String> arguments) async {
  // 步骤 1：推文 ID（裸 ID 或状态页 URL；缺省用已知向量）
  final String? tweetId = _resolveTweetId(arguments);
  if (tweetId == null) {
    _err('无法从参数解析出推文 ID（期望 15~20 位数字，或含 /status/{id} 的 URL）');
    _err('用法: dart run bin/smoke.dart <推文ID 或 推文URL>');
    return 1;
  }

  // 步骤 2：token 本地计算——复用 App 同源 Dart 移植实现，
  // 构成 §11.1「三重验证」中的真端点对账腿。
  final String token = getToken(tweetId);
  _info('tweetId = $tweetId');
  _info('token   = $token');
  if (tweetId == _kDefaultTweetId && token != _kExpectedToken) {
    _err(
      '已知向量不匹配：期望 token=$_kExpectedToken，实际=$token'
      '（Dart 移植回归失败，详见 test/core/token_test.dart）',
    );
    return 1;
  }

  final HttpClient client = HttpClient()..connectionTimeout = _kTimeout;
  try {
    // 步骤 3：主源端点解析
    final Uri endpoint = Uri.parse(
      _kEndpointTemplate
          .replaceFirst('{id}', tweetId)
          .replaceFirst('{token}', token),
    );
    _info('GET $endpoint');
    final HttpClientResponse resp = await _fetch(
      client,
      endpoint,
      <String, String>{HttpHeaders.acceptHeader: 'application/json'},
    );
    if (resp.statusCode != HttpStatus.ok) {
      _err('端点 HTTP ${resp.statusCode}（期望 200；404/dogpage 归 TweetNotFound）');
      return 1;
    }
    final String contentType =
        resp.headers.value(HttpHeaders.contentTypeHeader) ?? '';
    if (!contentType.contains('json')) {
      _warn('Content-Type 非 JSON：$contentType（疑似 dogpage HTML，App 内归 E04）');
    }
    final String body = await resp.transform(utf8.decoder).join();
    final dynamic decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      _err('响应不是 JSON 对象（结构漂移，App 内归 E07 EndpointDrift）');
      return 1;
    }
    if (decoded.isEmpty) {
      _err('端点返回 200 + 空 {}：token 未被接受（DESIGN §6.1 无 token 行为）');
      return 1;
    }
    final String? typename = decoded['__typename'] as String?;
    if (typename != 'Tweet') {
      _warn('__typename=$typename（期望 Tweet；结构漂移迹象，App 内归 E07）');
    }

    // 步骤 4：遍历 mediaDetails（多视频推文必须遍历，§6.3），选最高码率 MP4。
    final List<dynamic> mediaDetails =
        decoded['mediaDetails'] as List<dynamic>? ?? <dynamic>[];
    final List<Map<String, dynamic>> videoEntries = <Map<String, dynamic>>[];
    for (final dynamic m in mediaDetails) {
      if (m is! Map<String, dynamic>) {
        continue;
      }
      final String type = (m['type'] as String?) ?? '';
      if (type == 'video' || type == 'animated_gif') {
        videoEntries.add(m);
      }
    }
    if (videoEntries.isEmpty) {
      _err('mediaDetails 无 video/animated_gif 条目（非视频推文，App 内归 E05）');
      return 1;
    }
    int bestBitrate = -1;
    String bestUrl = '';
    for (final Map<String, dynamic> entry in videoEntries) {
      final dynamic videoInfo = entry['video_info'];
      if (videoInfo is! Map<String, dynamic>) {
        continue;
      }
      final dynamic variants = videoInfo['variants'];
      if (variants is! List<dynamic>) {
        continue;
      }
      for (final dynamic v in variants) {
        if (v is! Map<String, dynamic>) {
          continue;
        }
        final String variantType = (v['content_type'] as String?) ?? '';
        final int? bitrate = v['bitrate'] as int?;
        final String? url = v['url'] as String?;
        if (variantType != 'video/mp4' ||
            bitrate == null ||
            bitrate <= 0 ||
            url == null) {
          continue; // HLS 变体不暴露（§4.2/§12.9）；非 MP4 / 零码率跳过
        }
        _info('变体: ${_resolutionOf(url).padRight(9)} bitrate=$bitrate  $url');
        if (bitrate > bestBitrate) {
          bestBitrate = bitrate;
          bestUrl = url;
        }
      }
    }
    if (bestUrl.isEmpty) {
      _err('无可用 MP4 变体（content_type=video/mp4 且 bitrate>0）');
      return 1;
    }
    _info('选定最高码率: $bestBitrate bps');

    // 步骤 5：直链 Range 前 64KB 校验（video.twimg.com 实测支持 206，§1.2）
    final Uri videoUri = Uri.parse(bestUrl);
    final HttpClientResponse rangeResp = await _fetch(
      client,
      videoUri,
      <String, String>{HttpHeaders.rangeHeader: 'bytes=0-${_kRangeBytes - 1}'},
    );
    if (rangeResp.statusCode == HttpStatus.ok) {
      _warn('直链返回 200（Range 被忽略）——App 引擎按截断重写处理（DESIGN §4.3）');
    } else if (rangeResp.statusCode != HttpStatus.partialContent) {
      _err(
        '直链 HTTP ${rangeResp.statusCode}（期望 206；'
        '403/410=签名过期，App 内自动重解析刷新 URL）',
      );
      return 1;
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in rangeResp) {
      builder.add(chunk);
      if (builder.length >= _kRangeBytes) {
        // 200 大文件场景防止读全量；206 时 body 恰为请求长度，自然结束。
        break;
      }
    }
    final Uint8List bytes = builder.takeBytes();
    final int? totalSize = _totalSizeOf(rangeResp);
    final int expected = (totalSize != null && totalSize < _kRangeBytes)
        ? totalSize
        : _kRangeBytes;
    if (bytes.length != expected) {
      _err('落盘字节数不符：期望 $expected，实际 ${bytes.length}');
      return 1;
    }
    if (bytes.length >= 8 &&
        String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
      _info('MP4 ftyp 魔数校验通过');
    } else {
      _warn('未检出 ftyp 魔数（非致命提示，仅作参考）');
    }
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'xdown_smoke_',
    );
    final File sample = File('${tempDir.path}/range_first_64k.bin');
    await sample.writeAsBytes(bytes, flush: true);
    _info('样本已落盘: ${sample.absolute.path}（${bytes.length} bytes）');
    _info('PASS: 真端点冒烟通过（解析 200 + token 有效 + Range + 前 64KB 落盘校验）');
    return 0;
  } on TimeoutException catch (e) {
    _err('请求超时（>$_kTimeout）：$e');
    return 1;
  } on SocketException catch (e) {
    _err('网络异常：$e');
    return 1;
  } on FormatException catch (e) {
    _err('响应不是合法 JSON：$e');
    return 1;
  } finally {
    client.close(force: true);
  }
}

/// 从命令行参数解析推文 ID：容忍裸 ID（15~20 位，§4.1 校验口径）
/// 或 x.com/twitter.com 状态页 URL（含 /video/N 后缀、查询串）。
String? _resolveTweetId(List<String> arguments) {
  if (arguments.isEmpty) {
    _info('未提供参数，使用 DESIGN §6.2 已知向量推文 $_kDefaultTweetId');
    return _kDefaultTweetId;
  }
  final String input = arguments.first.trim();
  if (RegExp(r'^\d{15,20}$').hasMatch(input)) {
    return input;
  }
  final RegExpMatch? m = RegExp(r'/status(?:es)?/(\d{15,20})')
      .firstMatch(input);
  return m?.group(1);
}

/// 统一请求出口：普通浏览器 UA + 额外头 + 超时（超时口径见 _kTimeout 注释）。
Future<HttpClientResponse> _fetch(
  HttpClient client,
  Uri uri,
  Map<String, String> extraHeaders,
) async {
  final HttpClientRequest request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.userAgentHeader, _kUserAgent);
  extraHeaders.forEach(request.headers.set);
  return request.close().timeout(_kTimeout);
}

/// 从 Content-Range（`bytes 0-65535/1234567`）或 Content-Length 推断资源总大小。
int? _totalSizeOf(HttpClientResponse response) {
  final String contentRange =
      response.headers.value(HttpHeaders.contentRangeHeader) ?? '';
  final RegExpMatch? m = RegExp(r'/(\d+)\s*$').firstMatch(contentRange);
  if (m != null) {
    return int.tryParse(m.group(1)!);
  }
  return response.contentLength >= 0 ? response.contentLength : null;
}

/// 从直链 URL 提取分辨率标签（`/vid/avc1/1280x720/` 正则；
/// 响应无分辨率字段，§6.3 实测确认）。
String _resolutionOf(String url) {
  final RegExpMatch? m = RegExp(r'/(\d+)x(\d+)/').firstMatch(url);
  if (m == null) {
    return '未知';
  }
  return '${m.group(1)}x${m.group(2)}';
}
