/// 带有界重试的图片组件（缩略图自愈，2026-10-04）。
///
/// 为什么需要：ImageCache 对失败的加载会把 completer 永久留在
/// `_pendingImages`（framework image_cache.dart 仅在成功首帧或显式
/// evict 时移除——其注释原文直言死条目 "will never complete"），同一
/// key 的后续重建永远拿到死 completer，不重试、不清除：代理闪断或
/// 启动竞态失败一次，缩略图整个会话都显示破图图标。
///
/// 机制：错误后 [ImageProvider.evict] 驱逐死条目，经 [retryDelay]
/// 以换代 [ValueKey] 重建 Image（全新 Element → 全新 resolve → 全新
/// 加载），[RetryImage.maxRetries] 次后放弃（errorBuilder 常驻）。
/// 网络类瞬时故障（代理切换/闪断）通常一两轮即恢复。
library;

import 'dart:async';

import 'package:flutter/material.dart';

class RetryImage extends StatefulWidget {
  const RetryImage({
    super.key,
    required this.image,
    this.fit,
    this.errorBuilder,
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 3),
  });

  final ImageProvider image;

  final BoxFit? fit;

  /// 错误兜底视图；未提供时渲染灰底破图图标。
  final WidgetBuilder? errorBuilder;

  /// 最多重试次数（首次加载之外）。
  final int maxRetries;

  final Duration retryDelay;

  @override
  State<RetryImage> createState() => _RetryImageState();
}

class _RetryImageState extends State<RetryImage> {
  int _attempt = 0;
  bool _retryScheduled = false;
  Timer? _timer;

  @override
  void didUpdateWidget(covariant RetryImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) {
      _timer?.cancel();
      _retryScheduled = false;
      _attempt = 0;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _scheduleRetry() {
    // errorBuilder 随每次 build 触发：单轮错误只调度一次重试。
    if (_retryScheduled || _attempt >= widget.maxRetries) return;
    _retryScheduled = true;
    _timer = Timer(widget.retryDelay, () {
      if (!mounted) return;
      // 驱逐死条目（同 key 重建仍会命中死 completer，必须先 evict；
      // 经 ImageProvider.evict 走 obtainKey，ResizeImage 包装键也对）
      unawaited(widget.image.evict());
      setState(() {
        _attempt++;
        _retryScheduled = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Image(
      // 换代 key：强制重建 _ImageState → 重新 resolve → 全新加载
      key: ValueKey<int>(_attempt),
      image: widget.image,
      fit: widget.fit,
      errorBuilder: (_, _, _) {
        _scheduleRetry();
        final fallback = widget.errorBuilder;
        if (fallback != null) return fallback(context);
        return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(child: Icon(Icons.broken_image_outlined)),
        );
      },
    );
  }
}
