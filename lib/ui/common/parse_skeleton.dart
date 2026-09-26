/// 解析中骨架卡片 + 耗时计时器（DESIGN §1.3-#8 / §7.1-1，吸收 P2）。
///
/// 视觉评审主题 F 重做：
/// - 骨架结构与结果卡（PreviewCard）同构：16:9 封面块在上、头像+文字行在下
///   （此前上下相反，解析完成瞬间布局跳变）；
/// - 加载动效从整体透明度呼吸升级为扫光 shimmer（ShaderMask 渐变条扫过，
///   零第三方依赖）；
/// - 转圈 24dp 置于状态文字左侧组成标准加载行（此前 16dp 缩在角落存在感趋零）；
/// - 「取消解析」升级为全宽 OutlinedButton（31s 最坏等待的唯一出口，
///   此前是右下角小文字链）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:clipvault/core/app_strings.dart';

/// 解析等待骨架卡片
class ParseSkeleton extends StatefulWidget {
  const ParseSkeleton({
    super.key,
    this.retryAttempt = 0,
    this.maxRetries = 3,
    this.onCancel,
  });

  /// 当前网络退避重试轮次（1 起；0 = 首次尝试）。
  final int retryAttempt;

  /// 重试上限（与解析退避策略一致，默认 3）。
  final int maxRetries;

  /// 取消解析回调（null 时不显示取消按钮）。
  final VoidCallback? onCancel;

  @override
  State<ParseSkeleton> createState() => _ParseSkeletonState();
}

class _ParseSkeletonState extends State<ParseSkeleton>
    with SingleTickerProviderStateMixin {
  int _tickCount = 0;
  Timer? _timer;

  late final AnimationController _shimmer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() => _tickCount++);
    });
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final elapsed = (_tickCount * 100) / 1000.0;
    final retrying = widget.retryAttempt > 0;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 扫光只作用于骨架块（真实控件——状态行/取消钮——不参与）
          _Shimmer(
            controller: _shimmer,
            base: scheme.surfaceContainerHighest,
            highlight: scheme.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 与 PreviewCard 同构：16:9 封面块在上
                const AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _Bone(width: double.infinity, height: double.infinity),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 头像圆（32，与 PreviewCard CircleAvatar radius 16 等径）
                      const _Bone(width: 32, height: 32, circular: true),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            _Bone(width: double.infinity, height: 12),
                            SizedBox(height: 8),
                            _Bone(width: 160, height: 10),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                // 标准加载行：24dp 转圈在文字左侧
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    retrying
                        ? '${AppStrings.parseRetrying}'
                          '（${widget.retryAttempt}/${widget.maxRetries}）…'
                        : '${AppStrings.parsingInProgress} ${elapsed.toStringAsFixed(1)} s',
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.onCancel != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    textStyle: const TextStyle(fontSize: 14),
                  ),
                  onPressed: widget.onCancel,
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text(AppStrings.actionCancelParse),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 骨架灰块
class _Bone extends StatelessWidget {
  const _Bone({required this.width, required this.height, this.circular = false});

  final double width;
  final double height;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: circular ? null : BorderRadius.circular(10),
        shape: circular ? BoxShape.circle : BoxShape.rectangle,
      ),
    );
  }
}

/// 扫光 shimmer：渐变高亮条随 controller 自左向右扫过子树。
class _Shimmer extends StatelessWidget {
  const _Shimmer({
    required this.controller,
    required this.base,
    required this.highlight,
    required this.child,
  });

  final AnimationController controller;
  final Color base;
  final Color highlight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // t: -1 → 2（渐变条从完全在左侧扫到完全在右侧）
        final t = controller.value * 3 - 1;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment(t - 0.4, 0),
            end: Alignment(t + 0.4, 0),
            colors: [base, highlight, base],
            stops: const [0.35, 0.5, 0.65],
          ).createShader(bounds),
          child: child,
        );
      },
    );
  }
}
