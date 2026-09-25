/// 下载引擎全场景测试（DESIGN §11.1）。
///
/// 全部离线：本地 `HttpServer`（127.0.0.1 随机端口）mock CDN 行为，
/// 假时钟注入驱动退避与冷却，不触真实网络与平台插件通道。
/// 覆盖：206 正常续传 / 200 范围忽略重写 / 中断重连退避序列 /
/// 403 重解析回调（URL 刷新不丢进度）/ 429 全队列 30s 冷却 /
/// 并发上限 2 / 暂停恢复取消 / 速度滑窗与进度节流 / 恢复扫描 / 入册降级。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/download/download_engine.dart';
import 'package:clipvault/download/download_task.dart';
import 'package:clipvault/download/gallery_saver.dart';

// ---------------------------------------------------------------------------
// 测试基建
// ---------------------------------------------------------------------------

/// 假时钟：delay 即时推进虚拟时间并记录序列；可选 gate 阻塞下一次 delay，
/// 用于在冷却中段做同步观测。
///
/// gate 语义：阻塞期间保持可寻址（调用方经 `clock.gate!.complete()` 放行），
/// 放行后才清除——若消费时即置 null，测试将失去句柄无法释放（429 冷却
/// 用例在 `h.clock.gate!.complete()` 处空指针即源于此）。
class FakeClock {
  int _ms = 0;
  final List<Duration> delays = <Duration>[];
  Completer<void>? gate;

  DateTime now() => DateTime.fromMillisecondsSinceEpoch(_ms);

  Future<void> delay(Duration d) async {
    delays.add(d);
    _ms += d.inMilliseconds;
    final g = gate;
    if (g != null) {
      // 阻塞直至外部 complete；放行后清除，后续 delay 恢复即时推进。
      await g.future;
      gate = null;
    }
  }
}

/// 恒定值随机源（退避抖动确定性）。
class ConstRandom implements Random {
  ConstRandom(this.v);
  final double v;
  @override
  bool nextBool() => false;
  @override
  int nextInt(int max) => 0;
  @override
  double nextDouble() => v;
}

/// 零抖动随机源。
class ZeroRandom extends ConstRandom {
  ZeroRandom() : super(0.0);
}

/// 可编程 mock CDN：按路径路由，记录请求头与并发水位。
class MockServer {
  late final HttpServer _server;
  final Map<String, FutureOr<void> Function(HttpRequest)> routes =
      <String, FutureOr<void> Function(HttpRequest)>{};
  final List<String> requestLog = <String>[];
  int connections = 0;
  int maxConcurrent = 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest req) {
      connections++;
      if (connections > maxConcurrent) maxConcurrent = connections;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      requestLog.add('${req.method} ${req.uri.path} Range:${range ?? '-'}');
      Future(() async {
        try {
          final handler = routes[req.uri.path];
          if (handler == null) {
            req.response.statusCode = 404;
            await req.response.close();
          } else {
            await handler(req);
          }
        } catch (_) {
          // 客户端取消导致写失败等：mock 服务器吞掉
        } finally {
          connections--;
          try {
            await req.response.close();
          } catch (_) {
            // 已关闭：忽略
          }
        }
      });
    }, onError: (_) {
      // 服务器流错误：忽略
    });
  }

  String urlFor(String path) => 'http://127.0.0.1:${_server.port}$path';

  int hitsOf(String path) =>
      requestLog.where((l) => l.contains(' $path ')).length;

  Future<void> close() => _server.close(force: true);
}

/// 按 Range 语义提供字节体。
///
/// - [honorRange]：true 时带 Range 请求返回 206 + Content-Range（video.twimg.com
///   实测支持 Range，DESIGN §4.3）；false 时一律 200 全量（范围被忽略）。
/// - [drip]：分块间隔，制造多 chunk 流与可中断窗口。
/// - [shortBytes]：写够该字节数即提前关闭连接（声明了完整 content-length），
///   模拟"连接中断"。
Future<void> serveBody(
  HttpRequest req,
  Uint8List body, {
  bool honorRange = true,
  Duration drip = Duration.zero,
  int shortBytes = 0,
}) async {
  final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
  var start = 0;
  if (honorRange && rangeHeader != null) {
    final m = RegExp(r'bytes=(\d+)-').firstMatch(rangeHeader);
    if (m != null) start = int.parse(m.group(1)!);
  }
  final resp = req.response;
  final data = start > 0 ? body.sublist(start) : body;
  if (start > 0) {
    resp.statusCode = 206;
    resp.headers.set(HttpHeaders.contentRangeHeader,
        'bytes $start-${body.length - 1}/${body.length}');
  } else {
    resp.statusCode = 200;
  }
  resp.contentLength = data.length;
  const chunkSize = 1024;
  var written = 0;
  for (var i = 0; i < data.length; i += chunkSize) {
    if (shortBytes > 0 && written >= shortBytes) {
      // 已写够 shortBytes 即 close。实证（2026-09-25，Dart 3.13）：
      // dart:io HttpServer 对「声明 contentLength 但短写后 close」会抛
      // HttpException 并丢弃未发送缓冲——客户端收 0 字节数据 + 连接错误。
      // 因此本分支只适合制造「瞬态失败」（如退避耗尽测试）；
      // 需要断言 Range 续传（字节确实送达）的场景请用 RawHttpServer。
      await resp.close();
      return;
    }
    final end = i + chunkSize > data.length ? data.length : i + chunkSize;
    resp.add(data.sublist(i, end));
    written += end - i;
    await resp.flush();
    if (drip > Duration.zero) {
      await Future<void>.delayed(drip);
    }
  }
  await resp.close();
}

/// 固定返回指定状态码并立即关闭。
Future<void> serveStatus(HttpRequest req, int code) async {
  req.response.statusCode = code;
  await req.response.close();
}

/// 慢速 429：先发响应头，再以 100ms 间隔分块滴注 1KB 错误体——在客户端
/// 「响应头已到、错误体尚未排空」的 _drain 窗口内制造可观测的竞态注入点
///（用户此刻登记 cancel/pause 不得被冷却信号覆盖）。
Future<void> serveSlow429(HttpRequest req) async {
  req.response.statusCode = 429;
  req.response.contentLength = 1024;
  for (var i = 0; i < 4; i++) {
    req.response.add(Uint8List(256));
    await req.response.flush();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await req.response.close();
}

/// 裸 ServerSocket 手写 HTTP 服务器：精确模拟「写部分字节后连接中断」。
///
/// 为什么不用 HttpServer：实证（2026-09-25，Dart 3.13 / Win11 loopback）
/// dart:io HttpServer 对「声明 contentLength 但短写后 close()」会抛
/// HttpException 并丢弃服务端未发送缓冲——客户端收到 0 字节数据即遇
/// 连接错误，无法验证 Range 断点续传。裸 socket「按块写 + flush + 确认
/// 离机后 destroy」已实证客户端先收齐数据事件、再收
/// `Connection closed while receiving data`（见 tools/repro_loss.dart）。
class RawHttpServer {
  RawHttpServer(this.handler);

  /// 每个已解析请求的处理器（在 requestLog 记录之后调用）。
  final Future<void> Function(RawRequest req, RawResponder respond) handler;

  late final ServerSocket _socket;

  /// 与 MockServer 同格式的请求日志：`METHOD /path Range:<值|->`。
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
        if (headerEnd < 0) return; // 请求头未收全，继续累积
        unawaited(sub.cancel());
        _handle(client, text.substring(0, headerEnd));
      }, onDone: () {
        // 客户端先行关闭：无需处理
      });
    });
  }

  void _handle(Socket client, String headerBlock) {
    final lines = headerBlock.split('\r\n');
    final parts = lines.first.split(' ');
    final method = parts.isNotEmpty ? parts[0] : 'GET';
    final path = parts.length > 1 ? parts[1] : '/';
    String? range;
    for (final l in lines.skip(1)) {
      final idx = l.indexOf(':');
      if (idx <= 0) continue;
      final name = l.substring(0, idx).toLowerCase();
      if (name == 'range') range = l.substring(idx + 1).trim();
    }
    requestLog.add('$method $path Range:${range ?? '-'}');
    unawaited(handler(RawRequest(method, path, range), RawResponder(client)));
  }

  String urlFor(String path) => 'http://127.0.0.1:${_socket.port}$path';

  int hitsOf(String path) =>
      requestLog.where((l) => l.contains(' $path ')).length;

  Future<void> close() => _socket.close();
}

/// 裸服务器已解析的请求。
class RawRequest {
  RawRequest(this.method, this.path, this.range);

  final String method;
  final String path;
  final String? range;

  /// Range 起始字节；无 Range 头为 0。
  int get rangeFrom {
    final m = RegExp(r'bytes=(\d+)-').firstMatch(range ?? '');
    return m == null ? 0 : int.parse(m.group(1)!);
  }
}

/// 裸服务器的响应写入器。
class RawResponder {
  RawResponder(this._socket);

  final Socket _socket;

  /// 完整响应 [body]（请求带 Range 时自动 206 + Content-Range 续传）。
  Future<void> serveFull(RawRequest req, List<int> body) async {
    final from = req.rangeFrom;
    final data = from > 0 ? body.sublist(from) : body;
    final head = from > 0
        ? 'HTTP/1.1 206 Partial Content\r\n'
            'Content-Range: bytes $from-${body.length - 1}/${body.length}\r\n'
            'Content-Length: ${data.length}\r\n'
            'Connection: close\r\n\r\n'
        : 'HTTP/1.1 200 OK\r\n'
            'Content-Length: ${data.length}\r\n'
            'Connection: close\r\n\r\n';
    _socket.write(head);
    await _socket.flush();
    _socket.add(data);
    await _socket.flush();
    await _socket.close();
  }

  /// 纯状态码响应（如 403）。
  Future<void> serveStatus(int code, String reason) async {
    _socket.write('HTTP/1.1 $code $reason\r\n'
        'Content-Length: 0\r\n'
        'Connection: close\r\n\r\n');
    await _socket.flush();
    await _socket.close();
  }

  /// 「中断」响应：声明 [body] 全长但只写（自 Range 起）[interruptAfter]
  /// 字节，确认字节离开本机后 destroy——客户端先收数据、后收连接错误。
  Future<void> serveInterrupted(
      RawRequest req, List<int> body, int interruptAfter) async {
    final from = req.rangeFrom;
    final data = body.sublist(from, from + interruptAfter);
    final head = from > 0
        ? 'HTTP/1.1 206 Partial Content\r\n'
            'Content-Range: bytes $from-${body.length - 1}/${body.length}\r\n'
            'Content-Length: ${body.length - from}\r\n'
            'Connection: close\r\n\r\n'
        : 'HTTP/1.1 200 OK\r\n'
            'Content-Length: ${body.length}\r\n'
            'Connection: close\r\n\r\n';
    _socket.write(head);
    await _socket.flush();
    _socket.add(data);
    await _socket.flush();
    // 实证安全边际：字节离开本机后再销毁（过短会与 destroy 竞态丢数据）
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _socket.destroy();
  }
}

class FakeGallerySaver implements GallerySaver {
  FakeGallerySaver({this.outcome = GallerySaveOutcome.saved});
  GallerySaveOutcome outcome;
  final List<String> savedPaths = <String>[];

  @override
  Future<GallerySaveResult> saveVideo({
    required String path,
    required String album,
  }) async {
    if (outcome == GallerySaveOutcome.saved) savedPaths.add(path);
    return GallerySaveResult(
      outcome: outcome,
      savedAt:
          outcome == GallerySaveOutcome.saved ? DateTime.now() : null,
    );
  }
}

class RecordingStore implements DownloadStore {
  final List<DownloadTask> upserts = <DownloadTask>[];
  @override
  void upsert(DownloadTask task) => upserts.add(task);
}

/// 每用例一套：引擎 + mock 服务器 + 假时钟 + 临时目录。
class Harness {
  final MockServer server = MockServer();
  final FakeClock clock = FakeClock();
  final RecordingStore store = RecordingStore();
  final FakeGallerySaver gallery = FakeGallerySaver();
  late final Directory dir;
  late final DownloadEngine engine;

  Future<void> start({
    Duration progressThrottle = const Duration(milliseconds: 500),
    UrlRefresher? urlRefresher,
    int concurrency = 2,
  }) async {
    DownloadTask.resetIdSequenceForTest();
    dir = await Directory.systemTemp.createTemp('xdown_engine_test_');
    await server.start();
    engine = DownloadEngine(
      downloadDir: dir,
      gallerySaver: gallery,
      store: store,
      concurrency: concurrency,
      progressThrottle: progressThrottle,
      backoff: BackoffPolicy(random: ZeroRandom()),
      urlRefresher: urlRefresher,
      now: clock.now,
      delay: clock.delay,
    );
  }

  Future<void> teardown() async {
    await engine.dispose();
    await server.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // Windows 文件句柄延迟释放时忽略
    }
  }

  String pj(String name) => dir.path.endsWith(Platform.pathSeparator)
      ? '${dir.path}$name'
      : '${dir.path}${Platform.pathSeparator}$name';
}

/// 轮询等待条件成立（真实时间小额轮询；条件由 fake 时钟即时推进的事件驱动）。
Future<void> pumpUntil(
  bool Function() test, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('pumpUntil 超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Uint8List makeBody(int len) {
  final b = Uint8List(len);
  for (var i = 0; i < len; i++) {
    b[i] = i & 0xFF;
  }
  return b;
}

const testTweetId = '1790637656616943991';
const testBitrate = 2176000;

DownloadTask newTask(String url,
        {String tweetId = testTweetId, int bitrate = testBitrate}) =>
    DownloadTask.create(
      tweetId: tweetId,
      variantUrl: url,
      bitrate: bitrate,
      qualityLabel: '720p (HD)',
      tweetJson: <String, Object?>{'text': 'fixture'},
    );

// ---------------------------------------------------------------------------
// 纯单元：ParallelGate / BackoffPolicy / SpeedWindow / 状态机
// ---------------------------------------------------------------------------

void main() {
  test('ParallelGate：并发钳制 1-3，FIFO 唤醒', () async {
    final gate = ParallelGate(2);
    expect(gate.permits, 2);
    expect(gate.availablePermits, 2);
    final order = <int>[];
    final f1 = gate.acquire().then((_) => order.add(1));
    final f2 = gate.acquire().then((_) => order.add(2));
    final f3 = gate.acquire().then((_) => order.add(3));
    await Future<void>.delayed(Duration.zero);
    expect(order, <int>[1, 2]); // 第 3 个等待
    gate.release();
    await Future<void>.delayed(Duration.zero);
    expect(order, <int>[1, 2, 3]); // FIFO 获得
    await f1;
    await f2;
    await f3;
    gate.permits = 9;
    expect(gate.permits, 3); // 钳制上限 3
    gate.permits = 0;
    expect(gate.permits, 1); // 钳制下限 1
  });

  test('BackoffPolicy：800ms×2^n+抖动序列，3 次上限，封顶', () {
    final zero = BackoffPolicy(random: ZeroRandom());
    expect(zero.maxRetries, 3);
    expect(zero.delayFor(0).inMilliseconds, 800);
    expect(zero.delayFor(1).inMilliseconds, 1600);
    expect(zero.delayFor(2).inMilliseconds, 3200);
    // 抖动 = nextDouble() × base × 0.5
    final half = BackoffPolicy(random: ConstRandom(0.5));
    expect(half.delayFor(0).inMilliseconds, 1000);
    // 封顶
    final capped = BackoffPolicy(
      random: ZeroRandom(),
      maxDelay: const Duration(seconds: 2),
    );
    expect(capped.delayFor(5).inMilliseconds, 2000);
  });

  test('SpeedWindow：3s 滑窗速率', () {
    final w = SpeedWindow();
    DateTime t(int s) => DateTime.fromMillisecondsSinceEpoch(s * 1000);
    expect(w.speedBps, 0);
    w.add(0, t(0));
    expect(w.speedBps, 0); // 单样本无速率
    w.add(3000, t(3));
    expect(w.speedBps, 1000); // 3000B / 3s
    w.add(9000, t(10)); // t0 被驱逐，保留锚点 t3
    expect(w.speedBps, (6000 * 1000000.0 / 7000000).round()); // 857
    w.reset();
    expect(w.speedBps, 0);
    expect(w.sampleCount, 0);
  });

  test('任务状态机：幂等自环、合法转移、非法拒绝', () {
    final t = newTask('http://example.invalid/v.mp4');
    expect(t.status, DownloadStatus.queued);
    expect(identical(t.withStatus(DownloadStatus.queued), t), isTrue);
    final running = t.withStatus(DownloadStatus.running);
    expect(running.status, DownloadStatus.running);
    expect(
        running.withStatus(DownloadStatus.completed).status,
        DownloadStatus.completed);
    // queued → completed 非法
    expect(() => t.withStatus(DownloadStatus.completed), throwsStateError);
    // completed 硬终态
    final done = running.withStatus(DownloadStatus.completed);
    expect(() => done.withStatus(DownloadStatus.queued), throwsStateError);
    // copyWith 哨兵语义：省略保持、显式 null 清空
    final cleared = t.copyWith(
      status: DownloadStatus.failed,
      failureKind: DownloadFailureKind.retryable,
      errorMessage: 'x',
    );
    expect(cleared.failureKind, DownloadFailureKind.retryable);
    final healed = cleared.copyWith(
      status: DownloadStatus.queued,
      failureKind: null,
      errorMessage: null,
    );
    expect(healed.failureKind, isNull);
    expect(healed.errorMessage, isNull);
    expect(healed.variantUrl, t.variantUrl); // 未触碰字段保持
    expect(healed.tweetJson, t.tweetJson);
  });

  // -------------------------------------------------------------------------
  // 引擎 + 本地 HttpServer
  // -------------------------------------------------------------------------

  test('全新下载：200 全量 → 完成转正入册，节流抑制中间进度事件', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    final body = makeBody(10 * 1024);
    h.server.routes['/ok.mp4'] = (req) => serveBody(req, body);
    final task = newTask(h.server.urlFor('/ok.mp4'));
    final events = <DownloadTask>[];
    h.engine.taskEvents.listen(events.add);

    h.engine.enqueue(task);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.completed);

    final t = h.engine.task(task.id)!;
    // 首次请求无 Range（bytesDone=0 不带 Range 头）
    expect(h.server.requestLog.first, contains('Range:-'));
    // 文件转正 + 内容一致 + .part 消失
    expect(t.filePath, isNotNull);
    expect(t.partPath, isNotNull);
    expect(await File(t.filePath!).readAsBytes(), body);
    expect(await File(t.partPath!).exists(), isFalse);
    expect(t.bytesTotal, body.length);
    expect(t.bytesDone, body.length);
    // 入册成功：albumSavedAt 非空
    expect(t.albumSavedAt, isNotNull);
    expect(h.gallery.savedPaths, <String>[t.filePath!]);
    // 持久层收到完成快照
    expect(
        h.store.upserts.any((e) =>
            e.id == task.id && e.status == DownloadStatus.completed),
        isTrue);
    // 假时钟冻结 → 500ms 节流吞掉全部中间进度事件
    expect(
        events
            .where((e) =>
                e.status == DownloadStatus.running &&
                e.bytesDone > 0 &&
                e.bytesDone < body.length)
            .isEmpty,
        isTrue);
    expect(
        events.any((e) => e.status == DownloadStatus.completed), isTrue);
  });

  test('断点续传：预置 .part 以 Range 请求获得 206 续传', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    final body = makeBody(20 * 1024);
    h.server.routes['/resume.mp4'] = (req) => serveBody(req, body);
    // 预置 5120 字节断点文件（与引擎的 {tweetId}_{bitrate}.part 命名一致）
    final partPath = h.pj('${testTweetId}_$testBitrate.part');
    await File(partPath).writeAsBytes(body.sublist(0, 5120));

    final task = newTask(h.server.urlFor('/resume.mp4'));
    h.engine.enqueue(task);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.completed);

    final t = h.engine.task(task.id)!;
    expect(h.server.requestLog.first, contains('Range:bytes=5120-'));
    expect(h.server.requestLog.first, contains('/resume.mp4'));
    expect(await File(t.filePath!).readAsBytes(), body);
    expect(t.bytesDone, body.length);
  });

  test('200 范围被忽略：截断既有 .part 从零重写', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    final body = makeBody(8 * 1024);
    // honorRange=false：带 Range 也回 200 全量
    h.server.routes['/ignore.mp4'] =
        (req) => serveBody(req, body, honorRange: false);
    final partPath = h.pj('${testTweetId}_$testBitrate.part');
    final garbage = Uint8List(4 * 1024);
    for (var i = 0; i < garbage.length; i++) {
      garbage[i] = 0xFF;
    }
    await File(partPath).writeAsBytes(garbage);

    final task = newTask(h.server.urlFor('/ignore.mp4'));
    h.engine.enqueue(task);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.completed);

    final t = h.engine.task(task.id)!;
    expect(h.server.requestLog.first, contains('Range:bytes=4096-')); // 带了 Range
    // 服务器忽略范围 → 重写：垃圾字节被清除，内容与服务器一致
    expect(await File(t.filePath!).length(), body.length);
    expect(await File(t.filePath!).readAsBytes(), body);
  });

  test('连接中断：保留 .part 退避后续传，退避序列 800/1600ms', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    final body = makeBody(12 * 1024);
    // HttpServer 短写 close 会丢弃服务端缓冲（见 RawHttpServer 注释），
    // 断点续传断言改用裸 socket 精确模拟「写 3KB 后连接中断」。
    var hits = 0;
    final raw = RawHttpServer((req, respond) async {
      hits++;
      if (req.path == '/flaky.mp4' && hits <= 2) {
        // 前两次各写 3KB 即断连（声明完整 Content-Length）
        await respond.serveInterrupted(req, body, 3 * 1024);
      } else if (req.path == '/flaky.mp4') {
        await respond.serveFull(req, body);
      } else {
        await respond.serveStatus(404, 'Not Found');
      }
    });
    await raw.start();
    addTearDown(raw.close);

    final task = newTask(raw.urlFor('/flaky.mp4'));
    h.engine.enqueue(task);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.completed);

    expect(raw.hitsOf('/flaky.mp4'), 3);
    expect(h.clock.delays,
        <Duration>[const Duration(milliseconds: 800), const Duration(milliseconds: 1600)]);
    final t = h.engine.task(task.id)!;
    expect(t.autoRetries, 2);
    expect(await File(t.filePath!).readAsBytes(), body);
    // 三次请求的 Range 序列：无 → 3072- → 6144-
    expect(raw.requestLog[0], contains('Range:-'));
    expect(raw.requestLog[1], contains('Range:bytes=3072-'));
    expect(raw.requestLog[2], contains('Range:bytes=6144-'));
  });

  test('退避 3 次耗尽 → failed(retryable=true)，一键重试后成功', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    final body = makeBody(8 * 1024);
    var alwaysShort = true;
    h.server.routes['/exhaust.mp4'] = (req) async {
      if (alwaysShort) {
        await serveBody(req, body, shortBytes: 1024);
      } else {
        await serveBody(req, body);
      }
    };
    final task = newTask(h.server.urlFor('/exhaust.mp4'));
    h.engine.enqueue(task);
    await pumpUntil(() => h.engine.task(task.id)?.status == DownloadStatus.failed);

    var t = h.engine.task(task.id)!;
    expect(t.failureKind, DownloadFailureKind.retryable);
    expect(t.autoRetries, 3);
    expect(
        h.clock.delays,
        <Duration>[
          const Duration(milliseconds: 800),
          const Duration(milliseconds: 1600),
          const Duration(milliseconds: 3200),
        ]);
    expect(t.partPath, isNotNull);
    expect(await File(t.partPath!).exists(), isTrue); // .part 保留

    // 一键重试：计数与标记重置，服务器恢复后完成
    alwaysShort = false;
    h.engine.retry(task.id);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.completed);
    t = h.engine.task(task.id)!;
    expect(t.autoRetries, 0);
    expect(await File(t.filePath!).readAsBytes(), body);
  });

  test('403：重解析回调刷新直链，进度不丢', () async {
    final body = makeBody(10 * 1024);
    // 断点续传断言需字节确实送达（HttpServer 短写会丢缓冲，见 RawHttpServer 注释）
    var expiredHits = 0;
    final raw = RawHttpServer((req, respond) async {
      if (req.path == '/expired.mp4') {
        expiredHits++;
        if (expiredHits == 1) {
          // 首次：先服务 4KB 制造进度，然后断连
          await respond.serveInterrupted(req, body, 4 * 1024);
        } else {
          // 续传时签名过期
          await respond.serveStatus(403, 'Forbidden');
        }
      } else if (req.path == '/fresh.mp4') {
        await respond.serveFull(req, body);
      } else {
        await respond.serveStatus(404, 'Not Found');
      }
    });
    await raw.start();
    addTearDown(raw.close);

    final h = Harness();
    await h.start(urlRefresher: (tweetId, bitrate) async {
      expect(tweetId, testTweetId);
      expect(bitrate, testBitrate);
      return raw.urlFor('/fresh.mp4');
    });
    addTearDown(() => h.teardown());

    final task = newTask(raw.urlFor('/expired.mp4'));
    h.engine.enqueue(task);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.completed);

    final t = h.engine.task(task.id)!;
    expect(t.variantUrl, raw.urlFor('/fresh.mp4')); // URL 已刷新
    expect(t.urlRefreshed, isTrue);
    expect(await File(t.filePath!).readAsBytes(), body);
    // 进度不丢：第二次请求（续传）与刷新后请求都从 4096 起
    expect(raw.requestLog[1], contains('Range:bytes=4096-'));
    expect(raw.requestLog[2], contains('Range:bytes=4096-'));
    expect(raw.requestLog[2], contains('/fresh.mp4'));
  });

  test('403 且重解析回调失败 → failed(urlExpired)，不丢 .part', () async {
    final h = Harness();
    await h.start(urlRefresher: (tweetId, bitrate) async => null);
    addTearDown(() => h.teardown());

    h.server.routes['/always403.mp4'] = (req) => serveStatus(req, 403);
    final task = newTask(h.server.urlFor('/always403.mp4'));
    h.engine.enqueue(task);
    await pumpUntil(() => h.engine.task(task.id)?.status == DownloadStatus.failed);

    final t = h.engine.task(task.id)!;
    expect(t.failureKind, DownloadFailureKind.urlExpired);
    expect(t.urlRefreshed, isTrue);
    expect(h.clock.delays, isEmpty); // 刷新路径不消耗退避
  });

  test('404 → failed(permanent)，零退避', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    h.server.routes['/gone.mp4'] = (req) => serveStatus(req, 404);
    final task = newTask(h.server.urlFor('/gone.mp4'));
    h.engine.enqueue(task);
    await pumpUntil(() => h.engine.task(task.id)?.status == DownloadStatus.failed);

    final t = h.engine.task(task.id)!;
    expect(t.failureKind, DownloadFailureKind.permanent);
    expect(t.errorMessage, 'http-404');
    expect(h.clock.delays, isEmpty);
  });

  test('429 → 全队列 30s 冷却：暂停 running/queued，自动恢复完成', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    final bodyA = makeBody(6 * 1024);
    final bodyB = makeBody(6 * 1024);
    var aHits = 0;
    h.server.routes['/a.mp4'] = (req) async {
      aHits++;
      if (aHits == 1) {
        await serveStatus(req, 429);
      } else {
        await serveBody(req, bodyA);
      }
    };
    h.server.routes['/b.mp4'] =
        (req) => serveBody(req, bodyB, drip: const Duration(milliseconds: 20));

    final taskA = newTask(h.server.urlFor('/a.mp4'));
    final taskB = newTask(h.server.urlFor('/b.mp4'), tweetId: '2');
    final notices = <EngineNotice>[];
    h.engine.notices.listen(notices.add);
    // 阻塞冷却 30s 的假延迟，以便中段观测
    h.clock.gate = Completer<void>();

    h.engine.enqueue(taskA);
    h.engine.enqueue(taskB);
    await pumpUntil(() =>
        h.engine.task(taskA.id)?.status == DownloadStatus.paused &&
        h.engine.task(taskB.id)?.status == DownloadStatus.paused);

    // 冷却中：全队列暂停 + 引擎级状态
    expect(h.engine.cooling, isTrue);
    expect(h.engine.cooldownUntil, isNotNull);
    expect(h.engine.cooldownUntil!.millisecondsSinceEpoch, 30000);
    expect(h.engine.task(taskA.id)!.pausedForCooldown, isTrue);
    expect(h.engine.task(taskB.id)!.pausedForCooldown, isTrue);
    expect(
        h.clock.delays.where((d) => d.inSeconds == 30).length, 1);

    // 释放冷却：自动恢复并完成
    h.clock.gate!.complete();
    await pumpUntil(() =>
        h.engine.task(taskA.id)?.status == DownloadStatus.completed &&
        h.engine.task(taskB.id)?.status == DownloadStatus.completed);
    expect(await File(h.engine.task(taskA.id)!.filePath!).readAsBytes(),
        bodyA);
    expect(await File(h.engine.task(taskB.id)!.filePath!).readAsBytes(),
        bodyB);
    // 通知序列：冷却开始 → 结束
    expect(notices.length, 2);
    expect(notices[0].kind, EngineNoticeKind.rateLimitCooldownStarted);
    expect(notices[0].cooldownUntil, isNotNull);
    expect(notices[1].kind, EngineNoticeKind.rateLimitCooldownEnded);
    expect(h.engine.cooling, isFalse);
    expect(h.engine.cooldownUntil, isNull);
  });

  test('429 竞态：排水窗口内已登记的 cancel 优先，任务终态 canceled 不被冷却复活', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    h.server.routes['/rl-cancel.mp4'] = serveSlow429;
    final task = newTask(h.server.urlFor('/rl-cancel.mp4'));
    h.engine.enqueue(task);
    // 响应头已到、错误体仍在滴注：任务正处于 429 分支的 _drain 窗口内。
    await pumpUntil(() => h.server.hitsOf('/rl-cancel.mp4') >= 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    h.engine.cancel(task.id);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.canceled);

    // 用户取消意图胜出于冷却信号：终态 canceled（而非冷却 paused）。
    final t = h.engine.task(task.id)!;
    expect(t.status, DownloadStatus.canceled);
    expect(t.pausedForCooldown, isFalse);
    // 冷却即便排程也不得复活该任务：等待超过滴注窗口后仍为终态、无新请求。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(h.engine.task(task.id)!.status, DownloadStatus.canceled);
    expect(h.server.hitsOf('/rl-cancel.mp4'), 1);
  });

  test('429 竞态：排水窗口内已登记的 pause 优先，任务保持用户暂停不被冷却自动恢复', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    h.server.routes['/rl-pause.mp4'] = serveSlow429;
    final task = newTask(h.server.urlFor('/rl-pause.mp4'));
    h.engine.enqueue(task);
    await pumpUntil(() => h.server.hitsOf('/rl-pause.mp4') >= 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    h.engine.pause(task.id);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.paused);

    // 用户暂停语义（非冷却暂停）：不携带冷却标记，冷却结束也不自动复活。
    final t = h.engine.task(task.id)!;
    expect(t.status, DownloadStatus.paused);
    expect(t.pausedForCooldown, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(h.engine.task(task.id)?.status, DownloadStatus.paused);
    expect(h.server.hitsOf('/rl-pause.mp4'), 1);
  });

  test('429 冷却：冷却暂停期间用户显式暂停 → 转用户暂停，冷却结束不自动复活', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    final bodyA = makeBody(4 * 1024);
    final bodyB = makeBody(6 * 1024);
    var aHits = 0;
    h.server.routes['/rl2.mp4'] = (req) async {
      aHits++;
      if (aHits == 1) {
        await serveStatus(req, 429);
      } else {
        await serveBody(req, bodyA);
      }
    };
    // B 滴注慢放：确保 A 的 429 触发全队列冷却时 B 仍在 running，被冷却
    // 中断为 paused(cooldown)——作为「无用户信号任务」的对照组。
    h.server.routes['/other.mp4'] =
        (req) => serveBody(req, bodyB, drip: const Duration(milliseconds: 20));

    final taskA = newTask(h.server.urlFor('/rl2.mp4'));
    final taskB = newTask(h.server.urlFor('/other.mp4'), tweetId: '2');
    h.clock.gate = Completer<void>(); // 阻塞 30s 冷却计时，中段观测

    h.engine.enqueue(taskA);
    h.engine.enqueue(taskB);
    await pumpUntil(() =>
        h.engine.task(taskA.id)?.status == DownloadStatus.paused &&
        h.engine.task(taskB.id)?.status == DownloadStatus.paused);
    expect(h.engine.task(taskA.id)!.pausedForCooldown, isTrue);
    expect(h.engine.cooling, isTrue);

    // 冷却暂停期间用户对 A 显式再按暂停：转用户暂停语义（清冷却标记）。
    h.engine.pause(taskA.id);
    expect(h.engine.task(taskA.id)!.status, DownloadStatus.paused);
    expect(h.engine.task(taskA.id)!.pausedForCooldown, isFalse);

    // 释放冷却：无用户信号的 B 自动恢复并完成；A 保持用户暂停，不复活。
    h.clock.gate!.complete();
    await pumpUntil(() =>
        h.engine.task(taskB.id)?.status == DownloadStatus.completed);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(h.engine.task(taskA.id)?.status, DownloadStatus.paused);
    expect(h.server.hitsOf('/rl2.mp4'), 1); // A 未被冷却结束重新拉起
  });

  test('并发上限 2：三任务同时在队，服务器并发水位不超过 2', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    expect(h.engine.concurrency, 2);
    final ids = <String>[];
    for (var i = 0; i < 3; i++) {
      final body = makeBody(4 * 1024);
      final path = '/c$i.mp4';
      h.server.routes[path] =
          (req) => serveBody(req, body, drip: const Duration(milliseconds: 25));
      final task = newTask(h.server.urlFor(path), tweetId: '$i');
      ids.add(task.id);
      h.engine.enqueue(task);
    }
    await pumpUntil(() => ids
        .every((id) => h.engine.task(id)?.status == DownloadStatus.completed));
    expect(h.server.maxConcurrent, 2); // 恰好 2，绝无 3
    expect(h.gallery.savedPaths.length, 3);
  });

  test('暂停/恢复：保留 .part，恢复后从断点续传', () async {
    final h = Harness();
    await h.start(progressThrottle: Duration.zero);
    addTearDown(() => h.teardown());

    final body = makeBody(24 * 1024);
    h.server.routes['/slow.mp4'] =
        (req) => serveBody(req, body, drip: const Duration(milliseconds: 15));
    final task = newTask(h.server.urlFor('/slow.mp4'));
    h.engine.enqueue(task);
    await pumpUntil(() {
      final t = h.engine.task(task.id);
      return t != null &&
          t.status == DownloadStatus.running &&
          t.bytesDone > 0 &&
          t.bytesDone < body.length;
    });

    h.engine.pause(task.id);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.paused);
    final paused = h.engine.task(task.id)!;
    expect(paused.partPath, isNotNull);
    final pausedBytes = paused.bytesDone;
    expect(pausedBytes, greaterThan(0));
    expect(pausedBytes, lessThan(body.length));
    final partFile = File(paused.partPath!);
    expect(await partFile.exists(), isTrue);
    expect(await partFile.length(), greaterThanOrEqualTo(pausedBytes));
    // 幂等：重复暂停 no-op
    h.engine.pause(task.id);
    expect(h.engine.task(task.id)!.status, DownloadStatus.paused);

    h.engine.resume(task.id);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.completed);
    final t = h.engine.task(task.id)!;
    expect(await File(t.filePath!).readAsBytes(), body);
    // 恢复请求从实际断点续传
    expect(h.server.requestLog.last, contains('Range:bytes='));
    expect(h.server.requestLog.last, contains('/slow.mp4'));
  });

  test('取消：running → canceled 终态；retry 重新入队完成', () async {
    final h = Harness();
    await h.start(progressThrottle: Duration.zero);
    addTearDown(() => h.teardown());

    final body = makeBody(24 * 1024);
    h.server.routes['/cancel.mp4'] =
        (req) => serveBody(req, body, drip: const Duration(milliseconds: 15));
    final task = newTask(h.server.urlFor('/cancel.mp4'));
    h.engine.enqueue(task);
    await pumpUntil(() {
      final t = h.engine.task(task.id);
      return t != null &&
          t.status == DownloadStatus.running &&
          t.bytesDone > 0;
    });

    h.engine.cancel(task.id);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.canceled);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.server.hitsOf('/cancel.mp4'), 1); // 取消后不再有新请求
    expect(h.engine.task(task.id)!.partPath, isNotNull); // .part 保留

    // canceled → queued（重新下载）→ 从 .part 续传完成
    h.engine.retry(task.id);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.completed);
    expect(h.server.hitsOf('/cancel.mp4'), 2);
    expect(await File(h.engine.task(task.id)!.filePath!).readAsBytes(), body);
  });

  test('进度节流：throttle=0 时中间进度事件透出且单调', () async {
    final h = Harness();
    await h.start(progressThrottle: Duration.zero);
    addTearDown(() => h.teardown());

    final body = makeBody(8 * 1024);
    h.server.routes['/fast.mp4'] =
        (req) => serveBody(req, body, drip: const Duration(milliseconds: 5));
    final task = newTask(h.server.urlFor('/fast.mp4'));
    final progressEvents = <int>[];
    h.engine.taskEvents
        .where((e) => e.id == task.id && e.status == DownloadStatus.running)
        .listen((e) => progressEvents.add(e.bytesDone));

    h.engine.enqueue(task);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.completed);
    expect(progressEvents.length, greaterThan(1));
    for (var i = 1; i < progressEvents.length; i++) {
      expect(progressEvents[i], greaterThanOrEqualTo(progressEvents[i - 1]));
    }
    expect(progressEvents.last, body.length);
  });

  test('restoreFrom：.part 存在恢复进度续传；缺失归零重下', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    final body = makeBody(16 * 1024);
    h.server.routes['/r1.mp4'] = (req) => serveBody(req, body);
    h.server.routes['/r2.mp4'] = (req) => serveBody(req, body);

    final t1 = newTask(h.server.urlFor('/r1.mp4'));
    final part1 = h.pj('${t1.tweetId}_${t1.bitrate}.part');
    await File(part1).writeAsBytes(body.sublist(0, 6 * 1024));
    final rec1 =
        t1.copyWith(status: DownloadStatus.running, partPath: part1); // 崩溃残留

    final t2 = newTask(h.server.urlFor('/r2.mp4'), tweetId: '999');
    final rec2 = t2.copyWith(
      status: DownloadStatus.paused,
      partPath: h.pj('missing_${t2.tweetId}_${t2.bitrate}.part'),
      bytesDone: 2048,
    );

    await h.engine.restoreFrom(<DownloadTask>[rec1, rec2]);
    await pumpUntil(() =>
        h.engine.task(t1.id)?.status == DownloadStatus.completed &&
        h.engine.task(t2.id)?.status == DownloadStatus.completed);

    // 两任务并发恢复，请求到达顺序不定，按路径各自断言
    final r1Log =
        h.server.requestLog.firstWhere((l) => l.contains('/r1.mp4'));
    final r2Log =
        h.server.requestLog.firstWhere((l) => l.contains('/r2.mp4'));
    expect(r1Log, contains('Range:bytes=6144-')); // .part 存在 → 断点续传
    expect(r2Log, contains('Range:-')); // .part 缺失 → 归零重下
    expect(await File(h.engine.task(t1.id)!.filePath!).readAsBytes(), body);
    expect(await File(h.engine.task(t2.id)!.filePath!).readAsBytes(), body);
  });

  test('入册降级：权限被拒 albumSavedAt 置空，重存成功置值', () async {
    final h = Harness();
    await h.start();
    h.gallery.outcome = GallerySaveOutcome.permissionDenied;
    addTearDown(() => h.teardown());

    final body = makeBody(4 * 1024);
    h.server.routes['/perm.mp4'] = (req) => serveBody(req, body);
    final task = newTask(h.server.urlFor('/perm.mp4'));
    h.engine.enqueue(task);
    await pumpUntil(
        () => h.engine.task(task.id)?.status == DownloadStatus.completed);

    var t = h.engine.task(task.id)!;
    expect(t.albumSavedAt, isNull); // 置空语义：历史页出现重存入口
    expect(h.gallery.savedPaths, isEmpty);
    expect(await File(t.filePath!).readAsBytes(), body); // 沙盒副本仍有效

    // 重新保存至相册（§4.4 入口）
    h.gallery.outcome = GallerySaveOutcome.saved;
    final ok = await h.engine.resaveToGallery(task.id);
    expect(ok, isTrue);
    t = h.engine.task(task.id)!;
    expect(t.albumSavedAt, isNotNull);
    expect(h.gallery.savedPaths, <String>[t.filePath!]);
  });

  test('enqueue 防御：重复 id 拒绝；非 queued 拒绝', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    final task = newTask(h.server.urlFor('/x.mp4'));
    h.engine.enqueue(task);
    expect(() => h.engine.enqueue(task), throwsArgumentError);
    final bad = newTask(h.server.urlFor('/x.mp4'))
        .withStatus(DownloadStatus.paused);
    expect(() => h.engine.enqueue(bad), throwsArgumentError);
  });

  test('业务键去重：同 (tweetId, bitrate) 未终结任务重复入队抛 DuplicateActiveTaskException', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    // 挂起路由：首任务停在 running（未终结），稳定占据业务键。
    final hang = Completer<void>();
    h.server.routes['/hang.mp4'] = (req) => hang.future;

    final first = newTask(h.server.urlFor('/hang.mp4'));
    h.engine.enqueue(first);
    await pumpUntil(
        () => h.engine.task(first.id)?.status == DownloadStatus.running);

    // 同键重复入队：抛业务异常并携带既有任务定位信息。
    final dup = newTask(h.server.urlFor('/hang.mp4'));
    expect(
      () => h.engine.enqueue(dup),
      throwsA(isA<DuplicateActiveTaskException>()
          .having((e) => e.tweetId, 'tweetId', testTweetId)
          .having((e) => e.bitrate, 'bitrate', testBitrate)
          .having((e) => e.existingTaskId, 'existingTaskId', first.id)),
    );
    // 拒绝路径不登记任务、不产生事件。
    expect(h.engine.task(dup.id), isNull);

    // 不同 tweetId / 不同 bitrate 不受业务键限制，均可入队。
    h.engine.enqueue(newTask(h.server.urlFor('/hang.mp4'), tweetId: 'other'));
    h.engine
        .enqueue(newTask(h.server.urlFor('/hang.mp4'), bitrate: 832000));
  });

  test('业务键去重：completed 终态释放业务键，同 (tweetId, bitrate) 可重新入队', () async {
    final h = Harness();
    await h.start();
    addTearDown(() => h.teardown());

    final body = makeBody(4 * 1024);
    h.server.routes['/re.mp4'] = (req) => serveBody(req, body);

    final first = newTask(h.server.urlFor('/re.mp4'));
    h.engine.enqueue(first);
    await pumpUntil(
        () => h.engine.task(first.id)?.status == DownloadStatus.completed);

    // 终态不占用业务键：同键新任务（重新下载）不再抛异常，可完成。
    final second = newTask(h.server.urlFor('/re.mp4'));
    h.engine.enqueue(second);
    await pumpUntil(
        () => h.engine.task(second.id)?.status == DownloadStatus.completed);
    expect(h.engine.tasks.length, 2);
    expect(await File(h.engine.task(second.id)!.filePath!).readAsBytes(), body);
  });
}
