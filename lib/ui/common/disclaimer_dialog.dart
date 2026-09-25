/// 首启《使用协议》闸门弹窗（DESIGN §7 导航流 / §8.3 版本化）。
///
/// - 全屏语义 Dialog，barrier 不可点外关闭；
/// - 勾选复选框后「同意」才可用；
/// - 「不同意并退出」默认调用 SystemNavigator.pop() 退出（测试可注入 onDecline 记录）；
/// - 版本号展示 kCurrentDisclaimerVersion，条款升级递增后重新弹窗。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/settings/settings_controller.dart';

/// 展示免责声明弹窗；返回用户是否同意。
Future<bool> showDisclaimerDialog(
  BuildContext context, {
  VoidCallback? onDecline,
  bool barrierDismissible = false,
}) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    routeSettings: const RouteSettings(name: '/disclaimer'),
    builder: (dialogContext) => PopScope(
      canPop: barrierDismissible,
      child: Dialog(
        child: _DisclaimerContent(
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
  SystemNavigator.pop();
}

class _DisclaimerContent extends StatefulWidget {
  const _DisclaimerContent({required this.onDecline});

  final VoidCallback onDecline;

  @override
  State<_DisclaimerContent> createState() => _DisclaimerContentState();
}

class _DisclaimerContentState extends State<_DisclaimerContent> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
                  '${AppStrings.disclaimerTitle}（v$kCurrentDisclaimerVersion）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
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
