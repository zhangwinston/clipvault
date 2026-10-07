// 设置页 widget 测试（2026-10-04 代理项合并）：
// 单行高内聚代理设置项——Switch 独管启停；开启态副标题展示生效地址 +
// 编辑铅笔，整行点按唤起编辑弹窗（非法格式就地报错不关窗、合法保存后
// 副标题即时刷新）；关闭态副标题「未启用」且整行不可再编辑；
// 页面上不再常驻代理 TextField（TUN 长文收进弹窗 helper）。
// 设置经 SharedPreferences mock 离线注入，不触网络与磁盘。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/ui/settings/settings_screen.dart';

Future<void> _pumpSettings(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: SettingsScreen())),
  );
  await tester.pump(); // 设置异步恢复
  await tester.pump(); // 首帧完成
}

/// 滚动到代理行并完整入视口（scrollUntilVisible 命中 cacheExtent 内的
/// 离屏元素即停，需 ensureVisible 补一程——同 disclaimer_test 的教训）。
Future<void> _scrollToProxyRow(WidgetTester tester) async {
  final row = find.text(AppStrings.settingsProxyToggle);
  await tester.scrollUntilVisible(
    row,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(row);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'disclaimer.version': 1,
      'settings.proxyAddress': '127.0.0.1:2080',
      'settings.proxyEnabled': true,
    });
  });

  testWidgets('合并布局：开关与地址同row，页面无常驻输入框', (tester) async {
    await _pumpSettings(tester);
    await _scrollToProxyRow(tester);

    expect(find.text(AppStrings.settingsProxyToggle), findsOneWidget);
    // 副标题展示生效地址
    expect(
      find.textContaining(AppStrings.settingsProxyActiveNow),
      findsOneWidget,
    );
    // 地址编辑收进弹窗：页面不再常驻 TextField
    expect(find.byType(TextField), findsNothing);
    // 代理行内 Switch 开启（按行内精确定位，避开 Wi-Fi/备份开关）
    final proxyTile = find
        .ancestor(
          of: find.text(AppStrings.settingsProxyToggle),
          matching: find.byType(ListTile),
        )
        .first;
    final sw = tester
        .widget<Switch>(find.descendant(of: proxyTile, matching: find.byType(Switch)));
    expect(sw.value, isTrue);
  });

  testWidgets('整行点按唤起编辑弹窗：非法就地报错不关窗，合法保存后副标题刷新', (tester) async {
    await _pumpSettings(tester);
    await _scrollToProxyRow(tester);

    await tester.tap(find.text(AppStrings.settingsProxyToggle));
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.settingsProxyEditTitle), findsOneWidget);
    // TUN 提示收进弹窗 helper（不再常驻主界面）
    expect(find.text(AppStrings.settingsProxyManualHelper), findsOneWidget);

    // 非法格式：就地报错、弹窗不关
    await tester.enterText(find.byType(TextField), 'not-a-host');
    await tester.tap(find.text(AppStrings.actionSave));
    await tester.pump();
    expect(find.text(AppStrings.toastProxyInvalid), findsOneWidget);
    expect(find.text(AppStrings.settingsProxyEditTitle), findsOneWidget);

    // 合法格式：保存关窗，副标题即时刷新为新地址
    await tester.enterText(find.byType(TextField), '127.0.0.1:7890');
    await tester.tap(find.text(AppStrings.actionSave));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.settingsProxyEditTitle), findsNothing);
    expect(find.textContaining('127.0.0.1:7890'), findsOneWidget);
  });

  testWidgets('铅笔入口唤起同一弹窗', (tester) async {
    await _pumpSettings(tester);
    await _scrollToProxyRow(tester);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.settingsProxyEditTitle), findsOneWidget);
  });

  testWidgets('关闭开关：副标题「未启用」，整行不可再编辑', (tester) async {
    await _pumpSettings(tester);
    await _scrollToProxyRow(tester);

    final proxyTile = find
        .ancestor(
          of: find.text(AppStrings.settingsProxyToggle),
          matching: find.byType(ListTile),
        )
        .first;
    await tester.tap(find.descendant(of: proxyTile, matching: find.byType(Switch)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text(AppStrings.settingsProxyOffLabel), findsOneWidget);
    expect(find.textContaining(AppStrings.settingsProxyActiveNow), findsNothing);
    // 关闭态整行点按不再唤起编辑弹窗
    await tester.tap(find.text(AppStrings.settingsProxyToggle));
    await tester.pump();
    expect(find.text(AppStrings.settingsProxyEditTitle), findsNothing);
  });

  testWidgets('自动调节代理开关：默认开，切换落盘', (tester) async {
    await _pumpSettings(tester);
    await _scrollToProxyRow(tester);
    // 自动调节行紧随代理行之下，确保完整入视口再交互
    await tester.ensureVisible(find.text(AppStrings.settingsProxyAuto));
    await tester.pump();

    final autoTile = find
        .ancestor(
          of: find.text(AppStrings.settingsProxyAuto),
          matching: find.byType(ListTile),
        )
        .first;
    final sw = tester.widget<Switch>(
        find.descendant(of: autoTile, matching: find.byType(Switch)));
    expect(sw.value, isTrue); // 默认开启

    // 关闭：prefs 落盘
    await tester.tap(
        find.descendant(of: autoTile, matching: find.byType(Switch)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings.proxyAuto'), isFalse);
    // 代理开关本体不受影响（仍开启）
    final proxyTile = find
        .ancestor(
          of: find.text(AppStrings.settingsProxyToggle),
          matching: find.byType(ListTile),
        )
        .first;
    expect(
      tester.widget<Switch>(find
          .descendant(of: proxyTile, matching: find.byType(Switch)))
          .value,
      isTrue,
    );
  });
}
