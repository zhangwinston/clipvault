/// 首启《使用协议》闸门弹窗（DESIGN §7 导航流 / §8.3 版本化）。
///
/// - 全屏语义 Dialog，barrier 不可点外关闭；
/// - 勾选复选框后「同意」才可用；
/// - 三种场景区分（P1-1）：首启 / 条款升级重弹（正文前缀「条款已更新」，
///   老用户能看出为什么又弹）/ 设置页重看；
/// - 「不同意」默认仅 Android 调 SystemNavigator.pop() 退出（iOS 上该 API
///   对未模态呈现的根 VC 是空操作，退出不可靠——闸门侧改由调用方渲染
///   静态说明页承接拒绝路径，P2-2）。
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/settings/settings_controller.dart';

/// 弹窗场景。
enum DisclaimerScenario {
  /// 首次启动（从未同意过）。
  firstLaunch,

  /// 条款版本升级后的重弹（曾同意过旧版本）。
  updated,

  /// 设置页主动重看。
  review,
}

/// 展示免责声明弹窗；返回用户是否同意。
Future<bool> showDisclaimerDialog(
  BuildContext context, {
  VoidCallback? onDecline,
  bool barrierDismissible = false,
  Color? barrierColor,
  DisclaimerScenario scenario = DisclaimerScenario.firstLaunch,
}) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    routeSettings: const RouteSettings(name: '/disclaimer'),
    builder: (dialogContext) => PopScope(
      canPop: barrierDismissible,
      child: Dialog(
        child: _DisclaimerContent(
          scenario: scenario,
          onDecline: () {
            Navigator.of(dialogContext).pop(false);
            final handler = onDecline ?? _defaultDeclineExit;
            handler();
          },
        ),
      ),
    ),
  );
  return accepted ?? false;
}

void _defaultDeclineExit() {
  // 仅 Android 可靠退出；iOS 侧拒绝路径由闸门的静态说明页承接。
  if (Platform.isAndroid) {
    SystemNavigator.pop();
  }
}

class _DisclaimerContent extends StatefulWidget {
  const _DisclaimerContent({required this.onDecline, required this.scenario});

  final VoidCallback onDecline;
  final DisclaimerScenario scenario;

  @override
  State<_DisclaimerContent> createState() => _DisclaimerContentState();
}

class _DisclaimerContentState extends State<_DisclaimerContent> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUpdate = widget.scenario == DisclaimerScenario.updated;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gavel_outlined, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  // 条款升级场景标题明示「已更新」，不再让老用户误判 App 异常
                  isUpdate
                      ? '${AppStrings.disclaimerTitle}已更新（v$kCurrentDisclaimerVersion）'
                      : '${AppStrings.disclaimerTitle}（v$kCurrentDisclaimerVersion）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (isUpdate) ...[
            Text(
              AppStrings.disclaimerUpdatedPrefix,
              style: const TextStyle(fontWeight: FontWeight.w600, height: 1.5),
            ),
            const SizedBox(height: 6),
          ],
          const Text(
            // PRD §5 原文话术逐字保留
            AppStrings.disclaimerBody,
            style: TextStyle(height: 1.5),
          ),
          const SizedBox(height: 16),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _checked = !_checked),
            child: Row(
              children: [
                Checkbox(
                  value: _checked,
                  onChanged: (v) => setState(() => _checked = v ?? false),
                ),
                Expanded(child: Text(AppStrings.disclaimerCheckbox)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: widget.onDecline,
                child: const Text(AppStrings.disclaimerDecline),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _checked ? () => Navigator.of(context).pop(true) : null,
                child: const Text(AppStrings.disclaimerAgree),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
