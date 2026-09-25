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
/// 全屏旋转与 PiP 待真机验证后揭示（§12-3/§12-10）；widget 测试不触本页。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
  double _dragStartPosition = 0;
  // media_kit 音量域为 0~100（区别于 video_player 的 0~1）
  double _dragStartVolume = 100;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    MediaKit.ensureInitialized();
    final file = File(widget.filePath);
    if (!await file.exists()) {
      if (mounted) setState(() => _error = '文件不存在：${widget.filePath}');
      return;
    }
    final player = Player();
    final controller = VideoController(player);
    // 播放错误经流异步上报（open 不抛同步异常）
    player.stream.error.listen((e) {
      if (!mounted || e.isEmpty) return;
      setState(() => _error = e);
    });
    if (!mounted) {
      await player.dispose();
      return;
    }
    setState(() {
      _player = player;
      _controller = controller;
    });
    try {
      // open 默认自动播放（与旧实现行为一致）
      await player.open(Media(widget.filePath));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    _player?.playOrPause();
  }

  /// 横滑：按视频宽度比例映射为进度增量
  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    final p = _player;
    if (p == null) return;
    final width = MediaQuery.of(context).size.width;
    final ratioDelta = details.delta.dx / width;
    final duration = p.state.duration;
    final targetMs = (p.state.position + duration * ratioDelta)
        .inMilliseconds
        .clamp(0, duration.inMilliseconds);
    p.seek(Duration(milliseconds: targetMs));
  }

  /// 左半屏竖滑：音量（media_kit 域 0~100）
  void _onVerticalDragStart(DragStartDetails details) {
    _dragStartPosition = details.globalPosition.dy;
    _dragStartVolume = _player?.state.volume ?? 100;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final p = _player;
    if (p == null) return;
    if (details.globalPosition.dx > MediaQuery.of(context).size.width / 2) return;
    final height = MediaQuery.of(context).size.height;
    final delta = (_dragStartPosition - details.globalPosition.dy) / height;
    final volume = (_dragStartVolume + delta * 100).clamp(0.0, 100.0);
    p.setVolume(volume);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final player = _player;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _controlsVisible = !_controlsVisible),
        onHorizontalDragUpdate: _onHorizontalDragUpdate,
        onVerticalDragStart: _onVerticalDragStart,
        onVerticalDragUpdate: _onVerticalDragUpdate,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_error != null)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.white54, size: 48),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(_error!, style: const TextStyle(color: Colors.white70)),
                  ),
                ],
              )
            else if (controller != null)
              // libmpv 渲染视图（contain 适配，无需外部 AspectRatio）
              Center(child: Video(controller: controller)),
            if (_controlsVisible) _buildControls(context, player),
          ],
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
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
          const Spacer(),
          if (player != null && _error == null) ...[
            StreamBuilder<bool>(
              stream: player.stream.playing,
              initialData: player.state.playing,
              builder: (context, snap) => IconButton(
                iconSize: 56,
                color: Colors.white,
                icon: Icon(snap.data == true ? Icons.pause_circle : Icons.play_circle),
                onPressed: _togglePlay,
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
