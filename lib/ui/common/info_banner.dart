/// 统一状态横幅（UI-VISUAL-REVIEW 主题 C）。
///
/// 此前两类横幅（首页剪贴板 / 下载页 429 冷却）一个蓝紫 tertiaryContainer、
/// 一个青绿 secondaryContainer——同类提示两种色相，且都是通栏贴边无圆角
/// 无外边距的生硬色带。本组件收口横幅语言：
/// - secondaryContainer 底（保持品牌青绿色系）+ 12px 圆角 + 16/8 外边距；
/// - 左侧 4dp accent 竖条 + 显式 onSecondaryContainer 前景；
/// - [iconColor] 供警示语义图标染色（如冷却横幅的琥珀色沙漏）。
library;

import 'package:flutter/material.dart';

class InfoBanner extends StatelessWidget {
  const InfoBanner({
    super.key,
    required this.icon,
    required this.message,
    this.iconColor,
    this.emphasizeNumbers = false,
    this.semanticsLabel,
  });

  final IconData icon;

  /// 横幅正文（支持多行）。
  final String message;

  /// 图标色（默认 onSecondaryContainer；警示场景传琥珀等语义色）。
  final Color? iconColor;

  /// 是否等宽数字（倒计时防跳变抖动）。
  final bool emphasizeNumbers;

  /// 无障碍语义（liveRegion 由调用方包裹或在此提供描述）。
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Row(
            children: [
              // 左侧 4dp accent 竖条：可点关键入口的视觉锚
              Container(width: 4, color: scheme.onSecondaryContainer),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(
                    children: [
                      Icon(icon, size: 20, color: iconColor ?? scheme.onSecondaryContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          message,
                          style: TextStyle(
                            color: scheme.onSecondaryContainer,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            fontFeatures: emphasizeNumbers
                                ? const [FontFeature.tabularFigures()]
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 冷却/警示横幅的琥珀图标色（亮暗各一；fromSeed 的 tertiary 落在蓝紫域，
/// 脱离品牌色系，故警示语义用独立琥珀而非 tertiaryContainer）。
Color cooldownAmber(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFFFFB95C)
    : const Color(0xFFB26A00);
