/// 系统分享接收（P1，DESIGN §4.1-3）：
/// - Android manifest intent-filter 接收 x.com/twitter.com 分享文本（Step 7 配置）；
/// - 统一归一化为文本流，首页监听后自动填充并触发解析（§7 导航流）；
/// - 平台插件隔离在 [RealShareReceiver]，测试注入 [NoopShareReceiver]。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// 分享接收抽象
abstract class ShareReceiver {
  /// 冷启动分享文本（一次性）
  Future<String?> initialText();

  /// 运行中分享文本流
  Stream<String> sharedText();

  void dispose();
}

/// 生产实现：receive_sharing_intent 插件。
///
/// 插件 1.9.x 仅提供媒体列表 API（无独立文本通道）：文本/链接分享以
/// type=text/url 的 [SharedMediaFile.path] 承载，这里归一化为纯文本
///（与本文件头「统一归一化为文本流」约定一致；媒体文件分享忽略）。
class RealShareReceiver implements ShareReceiver {
  @override
  Future<String?> initialText() async {
    final media = await ReceiveSharingIntent.instance.getInitialMedia();
    final text = _textOf(media);
    // 消费后重置，避免同一初始分享被重复投递（插件约定）
    await ReceiveSharingIntent.instance.reset();
    return text;
  }

  @override
  Stream<String> sharedText() => ReceiveSharingIntent.instance
      .getMediaStream()
      .map(_textOf)
      .where((text) => text != null)
      .cast<String>();

  /// 取首个文本/链接型分享项的 path（该字段承载文本或 URL）。
  static String? _textOf(List<SharedMediaFile> media) {
    for (final file in media) {
      if (file.type == SharedMediaType.text ||
          file.type == SharedMediaType.url) {
        final text = file.path.trim();
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  @override
  void dispose() {}
}

/// 空实现：测试/未启用 P1 时使用
class NoopShareReceiver implements ShareReceiver {
  final StreamController<String?> _pending = StreamController<String?>.broadcast();

  @override
  Future<String?> initialText() async => null;

  @override
  Stream<String> sharedText() => _pending.stream.where((event) => event != null).cast<String>();

  @override
  void dispose() {
    _pending.close();
  }
}

/// 注入点：测试用 Noop/假实现 override
final Provider<ShareReceiver> shareReceiverProvider = Provider<ShareReceiver>((ref) {
  final receiver = RealShareReceiver();
  ref.onDispose(receiver.dispose);
  return receiver;
});
