// 最小复现 v2：裸 ServerSocket 手写 HTTP 响应 —— 写 N 字节后 destroy，
// 验证 HttpClient 流式消费端能否先收到数据事件、再收到错误。
import 'dart:async';
import 'dart:io';

Future<void> main() async {
  final server = await ServerSocket.bind('127.0.0.1', 0);
  const total = 4096;
  const send = 3072;

  server.listen((socket) async {
    // 读完请求（简单起见读到空行即响应）
    socket.listen((data) async {
      final reqText = String.fromCharCodes(data);
      if (!reqText.contains('\r\n\r\n')) return;
      final headers =
          'HTTP/1.1 200 OK\r\nContent-Length: $total\r\nConnection: close\r\n\r\n';
      socket.write(headers);
      await socket.flush();
      // 分 3 块写 3072 字节，每块 flush
      for (var i = 0; i < 3; i++) {
        socket.add(List.filled(1024, i + 1));
        await socket.flush();
      }
      // 确保字节离开本机后再销毁
      await Future<void>.delayed(const Duration(milliseconds: 200));
      socket.destroy();
    });
  });

  final client = HttpClient();
  final received = <int>[];
  final chunkSizes = <int>[];
  Object? error;
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/x'));
    final res = await req.close();
    print('status=${res.statusCode} contentLength=${res.contentLength}');
    await for (final c in res) {
      chunkSizes.add(c.length);
      received.addAll(c);
    }
  } catch (e) {
    error = e;
  }
  print('bytes=${received.length} chunks=$chunkSizes error=$error');
  await server.close();
  exit(0);
}
