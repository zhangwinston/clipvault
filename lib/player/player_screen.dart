/// 内置播放器（P1，DESIGN §4.5 / §7.1-5）：
/// media_kit（libmpv）+ 自绘手势层（横滑进度 / 左半屏竖滑音量 / 返回）。
///
/// 为何弃用官方 video_player：其 Android 后端（ExoPlayer/media3）在颜色
/// 元数据未指定的视频上初始化抛 PlatformException（"Unset color range,
/// Unset color transfer, false, 8bit Luma, 8bit Chroma"——部分机型编解码
/// 器 configure 时拒绝 unset ColorInfo），而 X CDN 的 MP4 普遍不带色彩
/// 信息，实测 100% 触发且上游无修复（DESIGN §9-5 预设 media_kit 候补）。
/// libmpv 后端对缺失色彩元数据宽容。注意 media_kit 1.2.x 已移除
/// video_player 兼容层，本页使用其原生 API（Player/VideoController/Video）。
///
/// P1-9 修复：
/// - 全屏切换（横屏 + 沉浸式系统栏，退出/返回时恢复）；
/// - 横滑进度改为「拖动预览 + 松手确认」（不再每帧 seek 大幅跳进度），
///   拖动中 HUD 显示目标时间；
/// - 左半屏竖滑音量带屏幕指示条（自动淡出），不再盲滑靠耳朵猜；
/// - 控件 3 秒无操作自动隐藏，点按唤回；
/// - 播放失败兜底文案（不渲染含沙盒路径的原始异常串）。
/// PiP 待真机验证后揭示（§12-3/§12-10）；widget 测试不触本页。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:clipvault/core/app_strings.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.filePath});

  final String filePath;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  Player? _player;
  VideoController? _controller;
  String? _error;
  bool _controlsVisible = true;
  bool _fullscreen = false;
  Timer? _hideTimer;

  // ---- 手势进度（拖动预览 + 松手确认）----
  bool _seeking = false;
  Duration _seekFrom = Duration.zero;
  double _seekRatioDelta = 0; // 相对 _seekFrom 的累计屏宽比例增量

  // ---- 音量 HUD（media_kit 音量域 0~100）----
  double _dragStartPosition = 0;
  double _dragStartVolume = 100;
  double _volume = 100;
  bool _volumeHudVisible = false;
  Timer? _volumeHudTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    MediaKit.ensureInitialized();
    final file = File(widget.filePath);
    if (!await file.exists()) {
      // 固定兜底文案：不向用户渲染含完整沙盒路径的原始异常串（P0-4）
      if (mounted) setState(() => _error = AppStrings.errPlayerLoad);
      return;
    }
    final player = Player();
    final controller = VideoController(player);
    // 播放错误经流异步上报（open 不抛同步异常）
    player.stream.error.listen((e) {
      if (!mounted || e.isEmpty) return;
      setState(() => _error = AppStrings.errPlayerLoad);
    });
    if (!mounted) {
      await player.dispose();
      return;
    }
    setState(() {
      _player = player;
      _controller = controller;
      _volume = player.state.volume;
    });
    try {
      // open 默认自动播放（与旧实现行为一致）
      await player.open(Media(widget.filePath));
      _scheduleAutoHide();
    } catch (_) {
      if (mounted) setState(() => _error = AppStrings.errPlayerLoad);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _volumeHudTimer?.cancel();
    _restoreOrientation();
    _player?.dispose();
    super.dispose();
  }

  void _restoreOrientation() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    if (next) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  // ---- 控件自动隐藏（播放中 3 秒无操作）----

  void _scheduleAutoHide() {
    _hideTimer?.cancel();
    final p = _player;
    if (p == null || !p.state.playing || _seeking) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_seeking) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleAutoHide();
  }

  // ---- 手势进度：拖动预览，松手确认 ----

  Duration get _duration => _player?.state.duration ?? Duration.zero;

  Duration get _previewTarget {
    final target = _seekFrom + _duration * _seekRatioDelta;
    if (target < Duration.zero) return Duration.zero;
    if (target > _duration) return _duration;
    return target;
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    final p = _player;
    if (p == null) return;
    setState(() {
      _seeking = true;
      _seekFrom = p.state.position;
      _seekRatioDelta = 0;
    });
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_seeking) return;
    final width = MediaQuery.of(context).size.width;
    setState(() => _seekRatioDelta += details.delta.dx / width);
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_seeking) return;
    _player?.seek(_previewTarget);
    setState(() => _seeking = false);
    _scheduleAutoHide();
  }

  // ---- 左半屏竖滑：音量（media_kit 域 0~100）+ HUD ----

  void _onVerticalDragStart(DragStartDetails details) {
    _dragStartPosition = details.globalPosition.dy;
    _dragStartVolume = _player?.state.volume ?? 100;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final p = _player;
    if (p == null) return;
    if (details.globalPosition.dx > MediaQuery.of(context).size.width / 2) {
      return; // 右半屏竖滑无功能（亮度调节待接平台插件）
    }
    final height = MediaQuery.of(context).size.height;
    final delta = (_dragStartPosition - details.globalPosition.dy) / height;
    final volume = (_dragStartVolume + delta * 100).clamp(0.0, 100.0);
    p.setVolume(volume);
    setState(() {
      _volume = volume;
      _volumeHudVisible = true;
    });
    _volumeHudTimer?.cancel();
    _volumeHudTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _volumeHudVisible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final player = _player;
    return PopScope(
      // 返回时恢复竖屏与系统栏
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _restoreOrientation();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onHorizontalDragStart: _onHorizontalDragStart,
          onHorizontalDragUpdate: _onHorizontalDragUpdate,
          onHorizontalDragEnd: _onHorizontalDragEnd,
          onVerticalDragStart: _onVerticalDragStart,
          onVerticalDragUpdate: _onVerticalDragUpdate,
          child: Semantics(
            label: '${AppStrings.playerSeekLabel}；${AppStrings.playerVolumeLabel}',
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            color: Colors.white54, size: 48),
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          style: const TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                else if (controller != null)
                  // libmpv 渲染视图（contain 适配，无需外部 AspectRatio）。
                  // controls 必须显式关闭：Video 默认携带 AdaptiveVideoControls
                  // （Material 白色进度条 + 圆形播放按钮），与本页自绘控件层
                  // 双层叠加；且外层手势拦截点击，自带层的自动隐藏永不触发，
                  // 表现为「白色进度条与按钮常驻遮挡画面」。
                  Center(
                    child: Video(
                      controller: controller,
                      // NoVideoControls 在 media_kit_video 中即 `const = null`
                      // （dynamic 字面量），strict-casts 下写显式 null 等价且
                      // 类型干净；语义：不使用自带控制层。
                      controls: null,
                    ),
                  ),
                // 拖动进度预览 HUD（目标时间 / 总时长）
                if (_seeking)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${_fmt(_previewTarget)} / ${_fmt(_duration)}',
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                // 音量指示条（左缘竖条，自动淡出；media_kit 域 0~100）
                if (_volumeHudVisible)
                  Positioned(
                    left: 24,
                    child: Container(
                      width: 6,
                      height: 160,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          heightFactor: (_volume / 100).clamp(0.0, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_controlsVisible) _buildControls(context, player),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context, Player? player) {
    return Positioned.fill(
      child: Column(
        children: [
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    tooltip: AppStrings.actionBack,
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  IconButton(
                    tooltip: _fullscreen
                        ? AppStrings.actionExitFullscreen
                        : AppStrings.actionFullscreen,
                    icon: Icon(
                      _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      color: Colors.white,
                    ),
                    onPressed: _toggleFullscreen,
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (player != null && _error == null) ...[
            StreamBuilder<bool>(
              stream: player.stream.playing,
              initialData: player.state.playing,
              builder: (context, snap) => IconButton(
                tooltip: AppStrings.actionPlayPause,
                iconSize: 56,
                color: Colors.white,
                icon: Icon(snap.data == true ? Icons.pause_circle : Icons.play_circle),
                onPressed: () {
                  player.playOrPause();
                  _scheduleAutoHide();
                },
              ),
            ),
            const SizedBox(height: 12),
            SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StreamBuilder<Duration>(
                    stream: player.stream.position,
                    initialData: player.state.position,
                    builder: (context, snap) {
                      final position = snap.data ?? Duration.zero;
                      final duration = player.state.duration;
                      final posMs = duration > Duration.zero
                          ? position.inMilliseconds.clamp(0, duration.inMilliseconds)
                          : 0;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${_fmt(position)} / ${_fmt(duration)}',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                          SizedBox(
                            height: 24,
                            child: Slider(
                              value: duration > Duration.zero
                                  ? posMs / duration.inMilliseconds
                                  : 0,
                              onChanged: (ratio) => player.seek(
                                Duration(
                                  milliseconds:
                                      (ratio * duration.inMilliseconds).round(),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
          const Spacer(),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
