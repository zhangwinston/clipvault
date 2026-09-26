/// 应用壳（DESIGN §7 IA / §9-12）：
/// - MaterialApp + Material 3 亮/暗主题（ThemeMode.system 跟随系统）；
/// - 底部 3 Tab（首页/下载/我的）+ IndexedStack 保活；
/// - 首启免责声明闸门（版本化 §8.3）；
/// - 生产侧 ProviderScope overrides 统一在 main.dart 装配。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/download/download_task.dart' as dt;
import 'package:clipvault/settings/settings_controller.dart';
import 'package:clipvault/ui/common/disclaimer_dialog.dart';
import 'package:clipvault/ui/downloads/downloads_screen.dart';
import 'package:clipvault/ui/downloads/task_tile.dart'
    show downloadEngineProvider, homeTabProvider;
import 'package:clipvault/ui/home/home_screen.dart';
import 'package:clipvault/ui/settings/settings_screen.dart';
import 'package:clipvault/ui/common/navigator_key.dart';

class XdownApp extends ConsumerWidget {
  const XdownApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      navigatorKey: navigatorKey,
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

  /// 最小品牌主题层（UI-VISUAL-REVIEW 主题 A：此前两主题仅 fromSeed、零组件定制，
  /// 主色占比实测 <1%——「朴素感」的最大单一来源）。
  ///
  /// - 卡片：elevation 0 + 12px 圆角 + surfaceContainerLow 底（亮暗都获得分组层次；
  ///   深色实测唯一有层次的区域正是带 Card 的引导卡）；
  /// - 输入框：filled + surfaceContainerHighest 底、聚焦 primary 2px（替换
  ///   「工程原型感」的默认黑灰细描边）；
  /// - 深色显式提亮主色（fromSeed 默认深色 primary 偏暗，按钮/选中态发闷）。
  static ThemeData _lightTheme() {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF00696F));
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
    );
  }

  static ThemeData _darkTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF00696F),
      brightness: Brightness.dark,
      primary: const Color(0xFF4CD9DE), // 深色提亮主色
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
    );
  }
}

/// 首启免责闸门：未同意（或条款版本升级）→ 品牌引导页 + 强制弹窗（§8.3）。
///
/// P1-1/P2-2 修复：
/// - 闸门背景不再是白屏，而是 logo + 三步示意品牌页（首屏自我解释）；
/// - 条款升级重弹时弹窗标题/正文明示「已更新」，老用户不再误判 App 故障；
/// - 拒绝路径渲染静态说明页承接（iOS 的 SystemNavigator.pop 对未模态呈现
///   的根 VC 是空操作，「退出失败→白屏上无限重弹」在此收敛为可逃离页面）。
class DisclaimerGate extends ConsumerStatefulWidget {
  const DisclaimerGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DisclaimerGate> createState() => _DisclaimerGateState();
}

class _DisclaimerGateState extends ConsumerState<DisclaimerGate> {
  bool _dialogShown = false;
  bool _declined = false;

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
        if (settings.needsDisclaimer && !_dialogShown && !_declined) {
          _dialogShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _showGate());
        }
        // 未同意条款前不挂载 child（§8.3「同意才放行」）：HomeShell/HomeScreen
        // 的分享冷启动消费（initialText → 自动解析）与剪贴板观察者只在
        // 闸门放行后才 initState，杜绝清晰度 Sheet 叠在免责弹窗之上被绕过。
        if (settings.needsDisclaimer) {
          if (_declined) {
            return _DisclaimerDeclinedPage(
              onReviewAgain: () => setState(() {
                _declined = false;
                _dialogShown = false; // 允许下一帧重新弹窗
              }),
            );
          }
          return const _GateBrandPage();
        }
        return widget.child;
      },
    );
  }

  Future<void> _showGate() async {
    if (!mounted) return;
    final settings = ref.read(settingsControllerProvider).value;
    final accepted = await showDisclaimerDialog(
      context,
      barrierDismissible: false,
      // 从未同意过（版本 0）= 首启；否则是条款升级重弹
      scenario: (settings?.disclaimerVersion ?? 0) == 0
          ? DisclaimerScenario.firstLaunch
          : DisclaimerScenario.updated,
    );
    if (!mounted) return;
    if (accepted) {
      await ref.read(settingsControllerProvider.notifier).acceptDisclaimer();
    } else {
      // 拒绝：不再白屏重弹，转静态说明页（Android 上弹窗默认已尝试退出，
      // 退出未完成时同样由此页承接）。
      setState(() => _declined = true);
    }
  }
}

/// 闸门品牌页：弹窗背景兼首屏自我解释（logo + 三步示意）。
class _GateBrandPage extends StatelessWidget {
  const _GateBrandPage();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget step(IconData icon, String text) => Row(
          children: [
            Icon(icon, color: scheme.primary, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        );
    return SizedBox.expand(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.movie_outlined, size: 40, color: scheme.primary),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppStrings.appName,
                          style: Theme.of(context).textTheme.headlineSmall),
                      Text(AppStrings.gateAppNameSubtitle,
                          style: TextStyle(
                              fontSize: 13, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 32),
              step(Icons.content_copy, AppStrings.gateStep1),
              const SizedBox(height: 16),
              step(Icons.search, AppStrings.gateStep2),
              const SizedBox(height: 16),
              step(Icons.save_alt, AppStrings.gateStep3),
            ],
          ),
        ),
      ),
    );
  }
}

/// 拒绝条款后的静态承接页（可逃离，不循环重弹）。
class _DisclaimerDeclinedPage extends StatelessWidget {
  const _DisclaimerDeclinedPage({this.onReviewAgain});

  /// 「重新查看协议」回调（回退到品牌页并重新弹窗）。
  final VoidCallback? onReviewAgain;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 40),
              const SizedBox(height: 16),
              Text(
                AppStrings.disclaimerDeclinedTitle,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                AppStrings.disclaimerDeclinedBody,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              if (onReviewAgain != null) ...[
                const SizedBox(height: 20),
                FilledButton.tonalIcon(
                  onPressed: onReviewAgain,
                  icon: const Icon(Icons.gavel_outlined),
                  label: const Text(AppStrings.disclaimerReviewAgain),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 3 Tab 主壳（首页 / 下载 / 我的）
///
/// - Tab 索引经 homeTabProvider（跨页导航：下载空态「去解析第一个视频」）；
/// - 订阅引擎任务事件流，下载完成时弹前台通知（P1-8：完成不再无声——
///   用户在别的 Tab 也能立刻知道结果，入册状态滞后 800ms 再读终态）。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  StreamSubscription<dynamic>? _taskSub;

  /// 已通知过完成的任务 id（重试后重新置 false 才会再次通知）。
  final Map<String, bool> _notifiedCompleted = <String, bool>{};

  @override
  void initState() {
    super.initState();
    final engine = ref.read(downloadEngineProvider);
    _taskSub = engine.taskEvents.listen(_onTaskEvent);
  }

  void _onTaskEvent(dt.DownloadTask task) {
    final wasCompleted = _notifiedCompleted[task.id] ?? false;
    _notifiedCompleted[task.id] = task.isCompleted;
    if (!task.isCompleted || wasCompleted) return;
    // 入册（albumSavedAt）在 completed 事件之后由引擎异步补写：
    // 稍等终态稳定再读，给出准确的完成文案。
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      final finalTask = ref.read(downloadEngineProvider).task(task.id);
      if (finalTask == null || !finalTask.isCompleted) return;
      final saved = finalTask.albumSavedAt != null;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(saved
                ? AppStrings.toastDownloadDone
                : AppStrings.toastDownloadDoneNoAlbum),
            action: SnackBarAction(
              label: AppStrings.actionView,
              onPressed: () =>
                  ref.read(homeTabProvider.notifier).select(1),
            ),
          ),
        );
    });
  }

  @override
  void dispose() {
    _taskSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(homeTabProvider);
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: const [
          HomeScreen(),
          DownloadsScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) =>
            ref.read(homeTabProvider.notifier).select(value),
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
