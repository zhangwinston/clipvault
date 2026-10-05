/// 本地优先缩略图（2026-10-05 用户决策：持久化记录的缩略图不依赖网络）。
///
/// 此前缩略图每次会话经网络拉取（ImageCache 仅内存缓存）——离线打开
/// 下载页/历史页即全量破图，且首节两轮代理竞态/滞留问题皆源于此。
/// 现改为本地文件渲染：路径确定性派生 `thumbs/{tweetId}_{fnv8(url)}.jpg`，
/// 本地缺失时才经统一代理出口拉取一次落盘（老记录免迁移自动本地化），
/// 此后永远离线可用。生命周期随记录行：删记录/清缓存时清理。
///
/// 解析预览卡（PreviewCard）是解析瞬间的在线 UI，不在此列，仍走网络。
library;

import 'dart:io';
import 'dart:ui' show Codec, ImmutableBuffer;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'package:clipvault/core/app_http.dart' show SystemProxy, createAppDio;

/// 缩略图落盘与清理（路径确定性派生，无 DB 依赖）。
class ThumbnailStore {
  ThumbnailStore._();

  /// 测试目录注入（优先于 path_provider 解析）。
  static Directory? debugDirOverride;

  static Directory? _resolved;

  /// 共享 Dio（统一代理出口；与 ProxyNetworkImage 同款语义）。
  static final Dio _dio = createAppDio();

  /// 同路径并发拉取去重（列表页多卡片同图并发首渲染）。
  static final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  /// 缩略图根目录（appDocuments/thumbs，懒创建）。
  static Future<Directory> _dir() async {
    final override = debugDirOverride;
    if (override != null) return override;
    final resolved = _resolved;
    if (resolved != null) return resolved;
    final docs = await getApplicationDocumentsDirectory();
    return _resolved =
        Directory('${docs.path}${Platform.pathSeparator}thumbs');
  }

  /// URL → 8 位 FNV-1a 十六进制（确定性、跨版本稳定；dart 的
  /// String.hashCode 无跨版本稳定性承诺，不能做文件名）。
  static String hash8(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// 缩略图文件句柄（不保证存在）。
  static Future<File> fileFor(String tweetId, String url) async {
    final dir = await _dir();
    if (!await dir.exists()) {
      // 懒创建（清缓存后目录被删的恢复路径）
      await dir.create(recursive: true);
    }
    return File(
        '${dir.path}${Platform.pathSeparator}${tweetId}_${hash8(url)}.jpg');
  }

  /// 本地缺失时经代理拉取一次落盘；已存在为 no-op。并发同路径去重。
  static Future<void> ensureFetched(String tweetId, String url) {
    final key = '${tweetId}_${hash8(url)}';
    return _inFlight.putIfAbsent(key, () async {
      try {
        final file = await fileFor(tweetId, url);
        if (await file.exists()) return;
        // 启动竞态防御：代理未就绪的直连必失败（同 ProxyNetworkImage）
        await SystemProxy.ready;
        final resp = await _dio.get<List<int>>(url,
            options: Options(responseType: ResponseType.bytes));
        final data = resp.data;
        if (data == null || data.isEmpty) {
          throw StateError('缩略图响应体为空: $url');
        }
        await file.writeAsBytes(data, flush: true);
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  /// 清理单条记录的缩略图（删记录时调用；best-effort）。
  static Future<void> purgeFor(String tweetId, String? url) async {
    if (url == null || url.isEmpty) return;
    try {
      final file = await fileFor(tweetId, url);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 占用/权限：忽略（清缓存兜底）
    }
  }

  /// 清空缩略图目录（清缓存时调用；懒重建，可再拉取）。
  static Future<void> purgeAll() async {
    try {
      final dir = await _dir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 占用/权限：忽略
    }
    _resolved = null;
  }
}

/// 本地优先缩略图 Provider：文件在则文件解码，否则拉取落盘后解码。
class LocalThumbnailImage extends ImageProvider<LocalThumbnailImage> {
  const LocalThumbnailImage(this.tweetId, this.url, {this.scale = 1.0});

  final String tweetId;

  /// 远端原图 URL（仅本地缺失时拉取一次；兼作文件名散列输入）。
  final String url;

  final double scale;

  @override
  Future<LocalThumbnailImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<LocalThumbnailImage>(this);

  @override
  ImageStreamCompleter loadImage(
      LocalThumbnailImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: key.scale,
    );
  }

  Future<Codec> _load(LocalThumbnailImage key, ImageDecoderCallback decode) async {
    final file = await ThumbnailStore.fileFor(key.tweetId, key.url);
    if (await file.exists()) {
      // 本地命中：零网络（fromFilePath 零拷贝解码）
      return decode(await ImmutableBuffer.fromFilePath(file.path));
    }
    await ThumbnailStore.ensureFetched(key.tweetId, key.url);
    return decode(await ImmutableBuffer.fromFilePath(file.path));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalThumbnailImage &&
          other.tweetId == tweetId &&
          other.url == url &&
          other.scale == scale;

  @override
  int get hashCode => Object.hash(tweetId, url, scale);

  @override
  String toString() => 'LocalThumbnailImage("$tweetId", "$url", scale: $scale)';
}

/// 带降采样的构造入口（与 proxyNetworkImage 同款 ResizeImage 语义）。
ImageProvider<Object> localThumbnail(String tweetId, String url,
        {int? cacheWidth}) =>
    cacheWidth == null
        ? LocalThumbnailImage(tweetId, url)
        : ResizeImage.resizeIfNeeded(
            cacheWidth, null, LocalThumbnailImage(tweetId, url));
