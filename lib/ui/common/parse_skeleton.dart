/// 解析中骨架卡片 + 耗时计时器（DESIGN §1.3-#8 / §7.1-1，吸收 P2）。
///
/// - 骨架块模拟预览卡布局（封面/头像/文字行）；
/// - 计时基于 100ms 周期 tick 计数（非墙钟），widget 测试 pump 即可确定性断言；
/// - 呼吸动画仅用 AnimatedOpacity 循环，零第三方依赖。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:clipvault/core/app_strings.dart';

/// 解析等待骨架卡片
class ParseSkeleton extends StatefulWidget {
  const ParseSkeleton({super.key});

  @override
  State<ParseSkeleton> createState() => _ParseSkeletonState();
}

class _ParseSkeletonState extends State<ParseSkeleton> {
  int _tickCount = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() => _tickCount++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final elapsed = (_tickCount * 100) / 1000.0;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const _BoneBox(width: 40, height: 40, circular: true),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      _BoneBox(width: double.infinity, height: 12),
                      SizedBox(height: 6),
                      _BoneBox(width: 160, height: 10),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const _BoneBox(width: double.infinity, height: 120),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${AppStrings.parsingInProgress} ${elapsed.toStringAsFixed(1)} s',
                    style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 骨架灰块（呼吸透明度）
class _BoneBox extends StatelessWidget {
  const _BoneBox({required this.width, required this.height, this.circular = false});

  final double width;
  final double height;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    return _Pulse(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: circular ? null : BorderRadius.circular(6),
          shape: circular ? BoxShape.circle : BoxShape.rectangle,
        ),
      ),
    );
  }
}

/// 呼吸动画容器
class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0.45,
      upperBound: 1,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _controller, child: widget.child);
  }
}
