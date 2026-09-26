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

/// 生产实现：系统剪贴板。
///
/// iOS 变化检测（P1-2 根治）：iOS 16+ 每次程序化读取粘贴板都会弹
/// 「已粘贴自…」系统横幅，而读取 `UIPasteboard.general.changeCount`
/// 不触发该提示。Dart 侧先经 `clipvault/clipboard` 通道取计数并与上次
/// 比对，内容未变直接返回 null（本次不读取文本 → 无系统提示）；
/// 通道未实现（Android/桌面/测试）时退回每次都读的原行为。
class SystemClipboardReader implements ClipboardReader {
  SystemClipboardReader();

  static const MethodChannel _changeCountChannel =
      MethodChannel('clipvault/clipboard');

  /// 进程内记忆的最近一次 changeCount（null = 未知，首读放行）。
  int? _lastChangeCount;

  /// 首次调用置 true 后，后续 changeCount 恒为 null（测试注入用）。
  static bool debugDisableChangeCount = false;

  Future<int?> _changeCount() async {
    if (debugDisableChangeCount) return null;
    try {
      return await _changeCountChannel.invokeMethod<int>('getChangeCount');
    } catch (_) {
      // 通道未注册（Android/桌面/测试环境）：null = 不做变化检测。
      return null;
    }
  }

  @override
  Future<String?> readText() async {
    final count = await _changeCount();
    if (count != null) {
      if (_lastChangeCount == count) return null; // 内容未变：跳过读取
      _lastChangeCount = count;
    }
    final data = await Clipboard.getData('text/plain');
    return data?.text;
  }
}

/// 注入点：测试用假 Reader override
final Provider<ClipboardReader> clipboardReaderProvider =
    Provider<ClipboardReader>((_) => SystemClipboardReader());

/// 剪贴板监听器：Notifier（待处理链接文本）+ 生命周期观察者。
///
/// 挂载方式：首页 initState 中 `WidgetsBinding.instance.addObserver(watcher)`，
/// dispose 时 removeObserver（watcher 内部亦注册了 onDispose 兜底）。
///
/// 去重语义（P2-1 修复）：会话内消费过的文本抑制重复横幅，但 App 进入
/// paused 时重置抑制——用户离开 App 重新复制同一链接再回来，横幅会再次
/// 出现（修复「同链接二次使用永不再提示」）；同一前台停留期内不重复打扰。
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
    if (state == AppLifecycleState.paused) {
      // 真正离开前台（inactive 只是权限弹窗等瞬时遮挡，不算）：
      // 重置去重——用户可能去别处重新复制了同一链接，回来应再次提示。
      _lastConsumed = null;
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final text = await ref.read(clipboardReaderProvider).readText();
    if (text == null || text.trim().isEmpty) return;
    // 复用 core 的推文 ID 提取做有效性判定（零网络请求，§6.5）
    final id = extractTweetId(text);
    if (id == null) return;
    // 去重：同一前台停留期内已消费的文本不重复打扰
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
