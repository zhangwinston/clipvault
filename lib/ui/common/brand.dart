/// 品牌视觉元素（UI-VISUAL-REVIEW 主题 A/G：零品牌资产 → 代码自绘品牌标记）。
///
/// 全项目此前不存在任何 logo/插画资产（pubspec 仅声明 config），AppBar 为
/// 纯文本标题——「视频 App 的界面上没有任何视频/播放视觉符号」。本文件用
/// 纯代码自绘品牌标记（零资产依赖）：
/// - [BrandMark]：青绿圆角方块 + 白色播放三角（上架图标同源语义），
///   AppBar 22px / 首启品牌页 64px 复用同一实现；
/// - [BrandTitle]：AppBar 标题（logo + 「Clip/Vault」双色字标）。
library;

import 'package:flutter/material.dart';
import 'package:clipvault/core/app_strings.dart';

/// 品牌标记：圆角方块（primary 底）+ 白色播放三角。
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 22});

  /// 边长（逻辑像素）；图标随比例缩放。
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(
        Icons.play_arrow,
        size: size * 0.72,
        color: scheme.onPrimary,
      ),
    );
  }
}

/// AppBar 品牌标题：logo + 双色字标（Clip=onSurface / Vault=primary）。
class BrandTitle extends StatelessWidget {
  const BrandTitle({super.key, this.markSize = 22});

  final double markSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandMark(size: markSize),
        const SizedBox(width: 8),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: AppStrings.appNameA,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextSpan(
                text: AppStrings.appNameB,
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
