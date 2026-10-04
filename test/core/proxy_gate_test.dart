/// 就绪门闩测试（缩略图回归 2026-10-04）。
///
/// ProxyNetworkImage 在 SystemProxy.markReady 前不发请求：启动竞态期
/// （代理解析/注入未完成）直连必失败，失败会被 ImageCache 永久滞留
/// （framework image_cache 的 _pendingImages 仅成功帧或显式 evict 移除）。
///
/// 本文件只含普通 test（真实 dart:io 网络路径）：不得混入 testWidgets——
/// binding 会装全局 HttpOverrides 把真实请求劫持为 400（flutter test
/// 按文件隔离 isolate，分文件即互不影响）。ImageProvider 解码回调需要
/// PaintingBinding，故此处手动 ensureInitialized 并还原 HttpOverrides
/// （恢复真实网络，仅本 isolate 生效）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImmutableBuffer;

import 'package:flutter/painting.dart'
    show ImageConfiguration, ImageStreamListener;
import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/core/app_http.dart' show SystemProxy;
import 'package:clipvault/core/proxy_image.dart';

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
  // ImageProvider 解码需要 PaintingBinding；binding 初始化会装
  // HttpOverrides（所有请求假 400），还原以走真实 dart:io 网络
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  tearDown(() {
    SystemProxy.debugReset(); // 恢复就绪态，防污染其他文件外的语义
  });

  test('门闩：markReady 前 ProxyNetworkImage 不发请求，放行后才拉取',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var hits = 0;
    unawaited(server.forEach((req) async {
      hits++;
      req.response.add(_transparentPng);
      await req.response.close();
    }));

    SystemProxy.debugReset(ready: false); // 模拟启动竞态：代理未就绪
    final img = ProxyNetworkImage('http://127.0.0.1:${server.port}/t.png');
    final loaded = Completer<void>();
    final stream = img.resolve(ImageConfiguration.empty);
    stream.addListener(ImageStreamListener((i, _) {
      i.dispose();
      if (!loaded.isCompleted) loaded.complete();
    }));

    // 未就绪窗口内：不发请求（直连失败即永久滞留，必须挡住）
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hits, 0, reason: '就绪门闩放行前不得发直连请求');

    SystemProxy.markReady();
    await loaded.future.timeout(const Duration(seconds: 5));
    expect(hits, 1);
    expect(ImmutableBuffer.fromUint8List(_transparentPng), isNotNull);
  });
}
