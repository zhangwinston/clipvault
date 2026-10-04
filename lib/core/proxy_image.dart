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

import 'package:clipvault/core/app_http.dart' show SystemProxy, createAppDio;

/// 网络图片加载器：URL 直连改为统一 HTTP 出口（手动/系统代理随 §6.9 开关）。
class ProxyNetworkImage extends ImageProvider<ProxyNetworkImage> {
  const ProxyNetworkImage(this.url, {this.scale = 1.0});

  final String url;
  final double scale;

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
    // 启动竞态防御（2026-10-04）：代理解析/注入完成前的请求会以 DIRECT
    // 直连 pbs.twimg.com——代理环境下必失败，且 ImageCache 会把失败的
    // completer 永久滞留（同 key 永不重试）。先等就绪门闩（2s 兜底）。
    await SystemProxy.ready;
    final resp = await _dio.get<List<int>>(
      key.url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('图片响应体为空：${key.url}');
    }
    // ImageDecoderCallback 入参是 ImmutableBuffer（非 Uint8List），且 3.47
    // 已无 cacheWidth 具名参数——降采样经 [proxyNetworkImage] 的 ResizeImage
    // 包装注入，此处仅按位置调用 decode，对回调签名演进免疫。
    final buffer =
        await ImmutableBuffer.fromUint8List(Uint8List.fromList(data));
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProxyNetworkImage && other.url == url && other.scale == scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() => 'ProxyNetworkImage("$url", scale: $scale)';
}

/// 带 decode 降采样的构造入口（等价旧 `Image(cacheWidth:)` 语义）：
/// 经 [ResizeImage] 包装——与基座 Image.network 系列同款机制，其内部
/// 与所在版本的 ImageDecoderCallback 签名自洽；未指定宽度则原样直出
/// [ProxyNetworkImage]（头像等原尺寸场景）。
ImageProvider<Object> proxyNetworkImage(String url, {int? cacheWidth}) {
  return cacheWidth == null
      ? ProxyNetworkImage(url)
      : ResizeImage.resizeIfNeeded(cacheWidth, null, ProxyNetworkImage(url));
}
