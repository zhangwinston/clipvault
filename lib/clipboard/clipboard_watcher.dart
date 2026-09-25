/// 剪贴板监听（DESIGN §4.1-2 / §8.2）：
/// - 仅在 App 生命周期 resume 时读取（Android 10+ 前台读取合规）；
/// - 命中推文链接则置待处理状态，由首页渲染内联横幅；
/// - 同一链接去重（consume 后不再重复打扰）；
/// - [ClipboardReader] 抽象注入，widget 测试不触真剪贴板通道。
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/core/url_extract.dart';

/// 剪贴板读取抽象（可测）
abstract class ClipboardReader {
  Future<String?> readText();
}

/// 生产实现：系统剪贴板
class SystemClipboardReader implements ClipboardReader {
  const SystemClipboardReader();

  @override
  Future<String?> readText() async {
    final data = await Clipboard.getData('text/plain');
    return data?.text;
  }
}

/// 注入点：测试用假 Reader override
final Provider<ClipboardReader> clipboardReaderProvider =
    Provider<ClipboardReader>((_) => const SystemClipboardReader());

/// 剪贴板监听器：Notifier（待处理链接文本）+ 生命周期观察者。
///
/// 挂载方式：首页 initState 中 `WidgetsBinding.instance.addObserver(watcher)`，
/// dispose 时 removeObserver（watcher 内部亦注册了 onDispose 兜底）。
class ClipboardWatcher extends Notifier<String?> with WidgetsBindingObserver {
  String? _lastConsumed;

  @override
  String? build() {
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
    });
    return null;
  }

  // 参数名与父类保持一致（state）；方法内如需访问 Notifier 的 state 用 this.state
  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state != AppLifecycleState.resumed) return;
    final text = await ref.read(clipboardReaderProvider).readText();
    if (text == null || text.trim().isEmpty) return;
    // 复用 core 的推文 ID 提取做有效性判定（零网络请求，§6.5）
    final id = extractTweetId(text);
    if (id == null) return;
    // 去重：同一链接（含同一分享文案）不重复打扰
    if (_lastConsumed == text) return;
    this.state = text;
  }

  /// 用户已处理横幅（点击解析或手动关闭）
  void consume() {
    _lastConsumed = state ?? _lastConsumed;
    state = null;
  }
}

final NotifierProvider<ClipboardWatcher, String?> clipboardWatcherProvider =
    NotifierProvider<ClipboardWatcher, String?>(ClipboardWatcher.new);
