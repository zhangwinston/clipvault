/// 代理感知的网络图片 Provider（缩略图回归修复，2026-09-30）。
///
/// 为什么不用 `Image.network`/`NetworkImage`：它们走 `dart:io` HttpClient
/// **直连**——既不读系统 Wi-Fi 代理，也不吃 App 的 [SystemProxy]（那只
/// 注入经 `createAppDio()` 构造的 Dio）。DNS 污染/代理环境下（§6.9 同
/// 根因），解析下载正常而缩略图/头像全部回落 broken_image 兜底图标。
///
/// 机制：经共享 Dio 实例（统一代理出口）拉 bytes → 标准 ImageProvider
/// 解码管线；ImageCache 按 key（URL）自动磁盘外内存缓存，接口与
/// `NetworkImage` 对齐（scale 语义同）。
library;

import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Codec, ImmutableBuffer;

import 'package:dio/dio.dart' show Dio, Options, ResponseType;
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/painting.dart';

import 'package:clipvault/core/app_http.dart' show createAppDio;

/// 网络图片加载器：URL 直连改为统一 HTTP 出口（手动/系统代理随 §6.9 开关）。
class ProxyNetworkImage extends ImageProvider<ProxyNetworkImage> {
  const ProxyNetworkImage(this.url, {this.scale = 1.0, this.cacheWidth});

  final String url;
  final double scale;

  /// 解码降采样宽度（null = 原尺寸）。基座 [Image] 构造器在 CI 锁定的
  /// Flutter 3.47 已无 cacheWidth 具名参数（Image.network 系列仍在），
  /// 降采样语义收进 Provider 的 decode 阶段实现。
  final int? cacheWidth;

  /// 全局共享 Dio（连接复用；findProxy 回调读 SystemProxy 实时缓存，
  /// 代理开关切换后新请求即走新设置）
  static final Dio _dio = createAppDio();

  @override
  Future<ProxyNetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<ProxyNetworkImage>(this);

  @override
  ImageStreamCompleter loadImage(
      ProxyNetworkImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: key.scale,
    );
  }

  Future<Codec> _load(ProxyNetworkImage key, ImageDecoderCallback decode) async {
    final resp = await _dio.get<List<int>>(
      key.url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('图片响应体为空：${key.url}');
    }
    // ImageDecoderCallback 入参是 ImmutableBuffer（非 Uint8List）
    final buffer =
        await ImmutableBuffer.fromUint8List(Uint8List.fromList(data));
    return decode(buffer, cacheWidth: key.cacheWidth);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProxyNetworkImage &&
          other.url == url &&
          other.scale == scale &&
          other.cacheWidth == cacheWidth;

  @override
  int get hashCode => Object.hash(url, scale, cacheWidth);

  @override
  String toString() =>
      'ProxyNetworkImage("$url", scale: $scale, cacheWidth: $cacheWidth)';
}
