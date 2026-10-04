/// RetryImage 自愈测试（缩略图回归 2026-10-04）。
///
/// ImageCache 对失败的加载把 completer 永久留在 _pendingImages（仅成功
/// 帧或显式 evict 移除），同 key 重建永不重载——RetryImage 以 evict +
/// 换代重建实现有界重试自愈。门闩（SystemProxy.ready）行为另见
/// proxy_gate_test.dart（真实网络路径须与 testWidgets 分文件隔离）。
library;

import 'dart:typed_data';
import 'dart:ui' show Codec, ImmutableBuffer;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/ui/common/retry_image.dart';

/// 1x1 透明 PNG（flutter 内部 kTransparentImage 未公开导出，本地内置）。
final Uint8List _transparentPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// 前 [failTimes] 次加载抛错、之后成功的测试 Provider（真实解码管线，
/// 帧/错误路径与生产 MultiFrameImageStreamCompleter 一致）。
class _FlakyImage extends ImageProvider<_FlakyImage> {
  const _FlakyImage({required this.id, required this.failTimes});

  /// 唯一标识：参与缓存键——用例间共用全局 ImageCache，同键会互相
  /// 命中彼此的死 completer（恰是本组件要对抗的框架行为）。
  final String id;

  final int failTimes;

  static int attempts = 0;

  @override
  Future<_FlakyImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_FlakyImage>(this);

  @override
  ImageStreamCompleter loadImage(_FlakyImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
    );
  }

  Future<Codec> _load(ImageDecoderCallback decode) async {
    attempts++;
    if (attempts <= failTimes) {
      throw StateError('flaky failure #$attempts');
    }
    final buffer = await ImmutableBuffer.fromUint8List(_transparentPng);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _FlakyImage && other.id == id && other.failTimes == failTimes;

  @override
  int get hashCode => Object.hash(id, failTimes);
}

void main() {
  setUp(_resetAttempts);

  testWidgets('失败后 evict 重试，恢复后自愈显示', (tester) async {
    const flaky = _FlakyImage(id: 'heal', failTimes: 1);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RetryImage(
          image: flaky,
          retryDelay: const Duration(milliseconds: 100),
          errorBuilder: (_) => const Text('ERR'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('ERR'), findsOneWidget, reason: '首次加载失败显示兜底');
    expect(_FlakyImage.attempts, 1);

    // 100ms 后自动重试（已 evict，全新加载）→ 成功 → 兜底消失
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(_FlakyImage.attempts, 2);
    expect(find.text('ERR'), findsNothing, reason: '重试成功后自愈');
  });

  testWidgets('持续失败时有界重试后停手（不无限打点）', (tester) async {
    const alwaysFail = _FlakyImage(id: 'bound', failTimes: 99);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RetryImage(
          image: alwaysFail,
          maxRetries: 2,
          retryDelay: const Duration(milliseconds: 50),
          errorBuilder: (_) => const Text('ERR'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(_FlakyImage.attempts, 1);
    // 两轮重试各推进 50ms
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    // 再留足时间也不得有第三轮
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(_FlakyImage.attempts, 3, reason: '首次 + 2 次重试后停手');
    expect(find.text('ERR'), findsOneWidget);
  });

  testWidgets('换图（provider 变更）重置重试计数', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: RetryImage(
          image: _FlakyImage(id: 'swap-a', failTimes: 99),
          maxRetries: 1,
          retryDelay: Duration(milliseconds: 50),
          errorBuilder: _errText,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(_FlakyImage.attempts, 2); // 首次 + 1 轮重试，停手

    // 换一张（不同 failTimes → 不同 provider）：计数归零重新开始
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: RetryImage(
          image: _FlakyImage(id: 'swap-b', failTimes: 98),
          maxRetries: 1,
          retryDelay: Duration(milliseconds: 50),
          errorBuilder: _errText,
        ),
      ),
    ));
    await tester.pump(); // didUpdateWidget → 计数重置 → 新一轮加载
    expect(_FlakyImage.attempts, 3, reason: '换图后重新开始计数并加载');
  });
}

Widget _errText(BuildContext _) => const Text('ERR');

void _resetAttempts() => _FlakyImage.attempts = 0;
