/// 内置播放器（P1，DESIGN §4.5 / §7.1-5）：
/// video_player 封装 + 手势层（横滑进度 / 左半屏竖滑音量 / 返回）。
/// 全屏旋转与 PiP 待真机验证后揭示（§12-3/§12-10）；widget 测试不触本页。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.filePath});

  final String filePath;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _controller;
  String? _error;
  bool _initialized = false;
  bool _controlsVisible = true;
  double _dragStartPosition = 0;
  double _dragStartVolume = 1;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final controller = VideoPlayerController.file(File(widget.filePath));
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _initialized = true);
      _controller = controller;
      await controller.play();
    } catch (e) {
      await controller.dispose();
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
  }

  /// 横滑：按视频宽度比例映射为进度增量
  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final width = MediaQuery.of(context).size.width;
    final ratioDelta = details.delta.dx / width;
    final target = c.value.position + c.value.duration * ratioDelta;
    c.seekTo(target);
  }

  /// 左半屏竖滑：音量
  void _onVerticalDragStart(DragStartDetails details) {
    _dragStartPosition = details.globalPosition.dy;
    _dragStartVolume = _controller?.value.volume ?? 1;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final c = _controller;
    if (c == null) return;
    if (details.globalPosition.dx > MediaQuery.of(context).size.width / 2) return;
    final height = MediaQuery.of(context).size.height;
    final delta = (_dragStartPosition - details.globalPosition.dy) / height;
    final volume = (_dragStartVolume + delta).clamp(0.0, 1.0);
    c.setVolume(volume);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
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
                  Text(_error!, style: const TextStyle(color: Colors.white70)),
                ],
              )
            else if (!_initialized)
              const CircularProgressIndicator()
            else if (controller != null)
              Center(child: AspectRatio(aspectRatio: controller.value.aspectRatio, child: VideoPlayer(controller))),
            if (_controlsVisible) _buildControls(context, controller),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context, VideoPlayerController? controller) {
    final position = controller?.value.position ?? Duration.zero;
    final duration = controller?.value.duration ?? Duration.zero;
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
          if (controller != null && _initialized)
            IconButton(
              iconSize: 56,
              color: Colors.white,
              icon: Icon(controller.value.isPlaying ? Icons.pause_circle : Icons.play_circle),
              onPressed: _togglePlay,
            ),
          const Spacer(),
          if (controller != null && _initialized)
            SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_fmt(position)} / ${_fmt(duration)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  VideoProgressIndicator(controller, allowScrubbing: true),
                ],
              ),
            ),
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
