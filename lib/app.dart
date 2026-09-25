/// 应用壳（DESIGN §7 IA / §9-12）：
/// - MaterialApp + Material 3 亮/暗主题（ThemeMode.system 跟随系统）；
/// - 底部 3 Tab（首页/下载/我的）+ IndexedStack 保活；
/// - 首启免责声明闸门（版本化 §8.3）；
/// - 生产侧 ProviderScope overrides 统一在 main.dart 装配。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/settings/settings_controller.dart';
import 'package:clipvault/ui/common/disclaimer_dialog.dart';
import 'package:clipvault/ui/downloads/downloads_screen.dart';
import 'package:clipvault/ui/home/home_screen.dart';
import 'package:clipvault/ui/settings/settings_screen.dart';

class XdownApp extends ConsumerWidget {
  const XdownApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      onGenerateTitle: (context) => AppStrings.appName,
      // Material 内置文案（Close tooltip / 日期选择器等）走 zh 代理（§9-12 文案收口）
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: _lightTheme(),
      darkTheme: _darkTheme(),
      themeMode: ThemeMode.system,
      home: const DisclaimerGate(child: HomeShell()),
    );
  }

  static ThemeData _lightTheme() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00696F)),
      );

  static ThemeData _darkTheme() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00696F),
          brightness: Brightness.dark,
        ),
      );
}

/// 首启免责闸门：未同意（或条款版本升级）→ 强制弹窗（§8.3）
class DisclaimerGate extends ConsumerStatefulWidget {
  const DisclaimerGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DisclaimerGate> createState() => _DisclaimerGateState();
}

class _DisclaimerGateState extends ConsumerState<DisclaimerGate> {
  bool _dialogShown = false;

  @override
  Widget build(BuildContext context) {
    final asyncSettings = ref.watch(settingsControllerProvider);
    return asyncSettings.when(
      loading: () => const SizedBox.expand(
        child: Center(child: CircularProgressIndicator()),
      ),
      // 固定文案收口（§9-12）：不向用户渲染原始异常串
      error: (e, _) =>
          const SizedBox.expand(child: Center(child: Text(AppStrings.errGeneric))),
      data: (settings) {
        if (settings.needsDisclaimer && !_dialogShown) {
          _dialogShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _showGate());
        }
        // 未同意条款前不挂载 child（§8.3「同意才放行」）：HomeShell/HomeScreen
        // 的分享冷启动消费（initialText → 自动解析）与剪贴板观察者只在
        // 闸门放行后才 initState，杜绝清晰度 Sheet 叠在免责弹窗之上被绕过。
        if (settings.needsDisclaimer) {
          return const SizedBox.expand();
        }
        return widget.child;
      },
    );
  }

  Future<void> _showGate() async {
    if (!mounted) return;
    final accepted = await showDisclaimerDialog(
      context,
      barrierDismissible: false,
    );
    if (!mounted) return;
    if (accepted) {
      await ref.read(settingsControllerProvider.notifier).acceptDisclaimer();
    } else {
      // 不同意即退出（§8.3）；退出失败（测试环境）时保持闸门，下帧重弹
      setState(() => _dialogShown = false);
    }
  }
}

/// 3 Tab 主壳（首页 / 下载 / 我的）
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          HomeScreen(),
          DownloadsScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: AppStrings.tabHome,
          ),
          NavigationDestination(
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download),
            label: AppStrings.tabDownloads,
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: AppStrings.tabSettings,
          ),
        ],
      ),
    );
  }
}
