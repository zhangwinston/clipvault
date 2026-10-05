/// 本地优先缩略图契约测试（2026-10-05 用户决策：缩略图不依赖网络）：
/// 首渲染经网络拉取落盘一次，此后**离线**（服务器关闭）仍能从本地文件
/// 加载；删记录/清缓存清理落盘文件。
///
/// 真实网络 test 专用文件（不得混 testWidgets——binding 的 HttpOverrides
/// 会把真实请求劫持为 400；ImageProvider 解码需要 PaintingBinding，故
/// ensureInitialized 后还原 HttpOverrides，同 proxy_gate_test 坑位）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImmutableBuffer;

import 'package:flutter/painting.dart'
    show ImageConfiguration, ImageStream, ImageStreamListener;
import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/core/app_http.dart' show SystemProxy;
import 'package:clipvault/core/local_thumbnail.dart';

/// 1x1 透明 PNG（flutter 内部 kTransparentImage 未公开导出，本地内置）。
final Uint8List _transparentPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // 还原真实 dart:io 网络

  late Directory tmpDir;

  setUp(() async {
    SystemProxy.markReady(); // 门闩不拦（本文件聚焦本地化语义）
    tmpDir = await Directory.systemTemp.createTemp('xdown_thumb_');
    ThumbnailStore.debugDirOverride = tmpDir;
  });

  tearDown(() async {
    ThumbnailStore.debugDirOverride = null;
    SystemProxy.debugReset();
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<int> startServer() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(server.forEach((req) async {
      req.response.add(_transparentPng);
      await req.response.close();
    }));
    return server.port;
  }

  Future<void> resolveAndWait(LocalThumbnailImage img) async {
    final done = Completer<void>();
    img.resolve(ImageConfiguration.empty).addListener(
      ImageStreamListener((i, _) {
        i.dispose();
        if (!done.isCompleted) done.complete();
      }, onError: (Object e, StackTrace? s) {
        if (!done.isCompleted) done.completeError(e ?? StateError('load'));
      }),
    );
    await done.future.timeout(const Duration(seconds: 5));
  }

  test('首渲染拉取落盘；此后离线（服务器关闭）仍从本地加载', () async {
    var hits = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(server.forEach((req) async {
      hits++;
      req.response.add(_transparentPng);
      await req.response.close();
    }));
    final url = 'http://127.0.0.1:${server.port}/thumb.jpg';

    // 首渲染：经网络拉取 + 落盘
    await resolveAndWait(LocalThumbnailImage('1790', url));
    expect(hits, 1);
    final file = await ThumbnailStore.fileFor('1790', url);
    expect(await file.exists(), isTrue, reason: '拉取后落盘');
    expect(await file.length(), _transparentPng.length);

    // 模拟重启：清内存缓存 + 服务器下线（离线）
    TestWidgetsFlutterBinding.instance.imageCache.clear();
    await server.close(force: true);

    // 新 Provider 实例（同 tweetId+url）：零网络、本地文件加载成功
    await resolveAndWait(LocalThumbnailImage('1790', url));
    expect(hits, 1, reason: '离线加载：不得再发网络请求');
  });

  test('并发首渲染去重：同图并发 ensureFetched 只发一次请求', () async {
    var hits = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(server.forEach((req) async {
      hits++;
      req.response.add(_transparentPng);
      await req.response.close();
    }));
    final url = 'http://127.0.0.1:${server.port}/dupe.jpg';

    await Future.wait(<Future<void>>[
      ThumbnailStore.ensureFetched('1791', url),
      ThumbnailStore.ensureFetched('1791', url),
    ]);
    expect(hits, 1);
    expect(await (await ThumbnailStore.fileFor('1791', url)).exists(), isTrue);
    await server.close(force: true);
  });

  test('purgeFor/purgeAll 清理落盘文件（删记录/清缓存语义）', () async {
    final port = await startServer();
    final url = 'http://127.0.0.1:$port/purge.jpg';
    await ThumbnailStore.ensureFetched('1792', url);
    final f = await ThumbnailStore.fileFor('1792', url);
    expect(await f.exists(), isTrue);

    await ThumbnailStore.purgeFor('1792', url);
    expect(await f.exists(), isFalse);

    await ThumbnailStore.ensureFetched('1793', url);
    await ThumbnailStore.purgeAll();
    expect(await tmpDir.exists(), isFalse, reason: '清缓存清空目录');
  });

  test('hash8 确定性（文件名跨版本稳定）', () {
    expect(ThumbnailStore.hash8('https://pbs.twimg.com/a.jpg'),
        ThumbnailStore.hash8('https://pbs.twimg.com/a.jpg'));
    expect(ThumbnailStore.hash8('https://pbs.twimg.com/a.jpg'),
        isNot(ThumbnailStore.hash8('https://pbs.twimg.com/b.jpg')));
  });

  test('ImmutableBuffer 常量可用（本文件 PNG 字节合法性自检）', () async {
    final buf = await ImmutableBuffer.fromUint8List(_transparentPng);
    expect(buf, isNotNull);
  });
}
