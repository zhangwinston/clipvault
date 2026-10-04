/// 代理路径断点续传回归（用户报告 2026-10-04：代理合入后疑似续传失效）。
///
/// 实证结论：dio/dart:io 经 findProxy 走字节管道代理（等同 sing-box
/// 转发语义）时，Range 头完整穿透、206 续传与失败后重试均正常——
/// 用户症状的真正根因在恢复扫描漏掉 failed 行（见
/// engine_commands_test「重启后重试失败任务」），本用例固化代理路径
/// 不回归。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/core/app_http.dart' show SystemProxy;
import 'package:clipvault/download/download_engine.dart';
import 'package:clipvault/download/download_task.dart';
import 'package:clipvault/download/gallery_saver.dart';

/// 字节管道正向代理：收到首个请求数据块后解析绝对 URI 请求行
/// （`GET http://host:port/path HTTP/1.1`），连到源站后双向原样转发。
/// 不改写字节——Range / Host / Accept 等头部完整穿透（与 sing-box
/// HTTP 入站的转发语义一致）。
class MiniForwardProxy {
  late final ServerSocket _socket;

  /// 每个连接的请求行日志（断言穿透性用）。
  final List<String> requestLines = <String>[];

  Future<void> start() async {
    _socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket.listen((client) {
      Socket? origin;
      var connected = false;
      var pending = <int>[];
      client.listen(
        (data) async {
          if (connected) {
            origin?.add(data);
            return;
          }
          pending.addAll(data);
          final text = latin1.decode(pending);
          final eol = text.indexOf('\r\n');
          if (eol < 0) return; // 头部未收全
          final reqLine = text.substring(0, eol);
          requestLines.add(reqLine);
          final uri = Uri.parse(reqLine.split(' ')[1]);
          connected = true;
          try {
            origin = await Socket.connect(uri.host, uri.port);
          } catch (_) {
            client.destroy();
            return;
          }
          origin!.write(text); // 首块（含完整请求头）原样转发
          origin!.listen(
            (od) => client.add(od),
            onDone: () => client.close(),
            onError: (_) => client.destroy(),
          );
        },
        onDone: () => origin?.close(),
        onError: (_) => client.destroy(),
        cancelOnError: true,
      );
    }, onError: (_) {});
  }

  String get proxyAddress => '127.0.0.1:${_socket.port}';

  Future<void> close() => _socket.close();
}

/// 裸 socket 源站请求。
class RawReq {
  RawReq(this.method, this.path, this.range);
  final String method;
  final String path;
  final String? range;
  int get rangeFrom {
    final m = RegExp(r'bytes=(\d+)-').firstMatch(range ?? '');
    return m == null ? 0 : int.parse(m.group(1)!);
  }
}

/// 裸 socket 源站（同 download_engine_test 的实证结论：HttpServer 短写会
/// 丢缓冲，必须裸 socket 才能模拟「字节送达后连接中断」）。
class RawOrigin {
  RawOrigin(this.handler);
  final Future<void> Function(RawReq req, Socket socket) handler;
  late final ServerSocket _socket;
  final List<String> requestLog = <String>[];

  Future<void> start() async {
    _socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket.listen((client) {
      final buf = <int>[];
      late final StreamSubscription<List<int>> sub;
      sub = client.listen((data) {
        buf.addAll(data);
        final text = latin1.decode(buf);
        final headerEnd = text.indexOf('\r\n\r\n');
        if (headerEnd < 0) return;
        unawaited(sub.cancel());
        final headerBlock = text.substring(0, headerEnd);
        final lines = headerBlock.split('\r\n');
        final parts = lines.first.split(' ');
        final path = parts.length > 1 ? parts[1] : '/';
        String? range;
        for (final l in lines.skip(1)) {
          final idx = l.indexOf(':');
          if (idx <= 0) continue;
          if (l.substring(0, idx).toLowerCase() == 'range') {
            range = l.substring(idx + 1).trim();
          }
        }
        requestLog.add('${parts[0]} $path Range:${range ?? '-'}');
        unawaited(handler(RawReq(parts[0], path, range), client));
      }, onDone: () {});
    }, onError: (_) {});
  }

  String urlFor(String path) => 'http://127.0.0.1:${_socket.port}$path';
  Future<void> close() => _socket.close();
}

/// 头部构造 + 写入助手（handler 内直接操作 socket）。
String rangeHead(int from, int total) => from > 0
    ? 'HTTP/1.1 206 Partial Content\r\n'
        'Content-Range: bytes $from-${total - 1}/$total\r\n'
        'Content-Length: ${total - from}\r\n'
        'Connection: close\r\n\r\n'
    : 'HTTP/1.1 200 OK\r\n'
        'Content-Length: $total\r\n'
        'Connection: close\r\n\r\n';

class FakeClock {
  int _ms = 0;
  final List<Duration> delays = <Duration>[];
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(_ms);
  Future<void> delay(Duration d) async {
    delays.add(d);
    _ms += d.inMilliseconds;
  }
}

class ZeroRandom implements Random {
  @override
  bool nextBool() => false;
  @override
  int nextInt(int max) => 0;
  @override
  double nextDouble() => 0.0;
}

class FakeGallerySaver implements GallerySaver {
  @override
  Future<GallerySaveResult> saveVideo(
      {required String path, required String album}) async {
    return GallerySaveResult(
        outcome: GallerySaveOutcome.saved, savedAt: DateTime.now());
  }
}

class RecordingStore implements DownloadStore {
  final List<DownloadTask> upserts = <DownloadTask>[];
  @override
  void upsert(DownloadTask task) => upserts.add(task);
}

Uint8List makeBody(int len) {
  final b = Uint8List(len);
  for (var i = 0; i < len; i++) {
    b[i] = i & 0xFF;
  }
  return b;
}

Future<void> pumpUntil(bool Function() test,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) fail('pumpUntil 超时');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  tearDown(() {
    SystemProxy.debugReset(); // 手动代理是静态全局：必须清，防污染其他用例
  });

  test('代理路径：中断耗尽失败 → 一键重试仍能 Range 断点续传', () async {
    final body = makeBody(16 * 1024);
    var interruptRemaining = 4; // 初次 + 3 次退避全部中断 → 任务 failed
    final origin = RawOrigin((req, socket) async {
      final from = req.rangeFrom;
      if (interruptRemaining > 0) {
        interruptRemaining--;
        // 声明全长但只送 3072 字节后断连（字节确实送达）
        final data = body.sublist(from, from + 3072);
        socket.write(rangeHead(from, body.length));
        await socket.flush();
        socket.add(data);
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        socket.destroy();
      } else {
        final data = body.sublist(from);
        socket.write(rangeHead(from, body.length));
        await socket.flush();
        socket.add(data);
        await socket.flush();
        await socket.close();
      }
    });
    await origin.start();
    final proxy = MiniForwardProxy();
    await proxy.start();
    addTearDown(origin.close);
    addTearDown(proxy.close);

    SystemProxy.setManualAddress(proxy.proxyAddress); // ← 代理生效

    final clock = FakeClock();
    final dir = await Directory.systemTemp.createTemp('xdown_proxy_repro_');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final engine = DownloadEngine(
      downloadDir: dir,
      gallerySaver: FakeGallerySaver(),
      store: RecordingStore(),
      backoff: BackoffPolicy(random: ZeroRandom()),
      now: clock.now,
      delay: clock.delay,
    );
    addTearDown(engine.dispose);

    final task = DownloadTask.create(
      tweetId: '1790637656616943991',
      variantUrl: origin.urlFor('/video.mp4'),
      bitrate: 2176000,
      qualityLabel: '720p (HD)',
      tweetJson: const <String, Object?>{'text': 'fixture'},
    );
    engine.enqueue(task);
    await pumpUntil(
        () => engine.task(task.id)?.status == DownloadStatus.failed);

    final failed = engine.task(task.id)!;
    expect(failed.failureKind, DownloadFailureKind.retryable);
    expect(failed.partPath, isNotNull);
    expect(await File(failed.partPath!).length(), 4 * 3072); // .part 有断点

    // 一键重试（用户操作）
    engine.retry(task.id);
    await pumpUntil(
        () => engine.task(task.id)?.status == DownloadStatus.completed);

    final done = engine.task(task.id)!;
    expect(await File(done.filePath!).readAsBytes(), body); // 内容完整
    // Range 序列：无 → 3072 → 6144 → 9216 → 12288（断点续传成立）
    expect(
        origin.requestLog.map((l) => l.split(' Range:').last).toList(),
        <String>[
          '-',
          'bytes=3072-',
          'bytes=6144-',
          'bytes=9216-',
          'bytes=12288-'
        ]);
    // 代理确实在路径上（全部请求经绝对 URI 进代理）
    expect(proxy.requestLines.length, 5);
    expect(proxy.requestLines.first, contains('http://127.0.0.1:'));
  });
}
