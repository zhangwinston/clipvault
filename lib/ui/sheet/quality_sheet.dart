/// 清晰度选择 BottomSheet（DESIGN §4.2 / §7.1-2）。
///
/// - 推文预览卡（头像/昵称/正文两行/时长封面/多视频 Chip）；
/// - 变体列表按码率降序（上游契约保证降序，此处再防御性排一次）；
/// - 行模板：`720p (HD)` 主标识 + 副行 `2.18 Mbps · 约 24.5 MB · MP4`；
/// - 默认高亮档由调用方按偏好计算（preferredVariantIndex 对新视频重匹配，
///   「省流 720p」切换视频后不再错档）；
/// - 仅 MP4 档（HLS 已在解析层裁剪，§12.9）；
/// - 多视频推文：Chip 切换经 [onSwitchVideo] 按视频序号重新解析
///   （TweetParser.resolve 的 videoIndex 参数）；失败不再静默——
///   SnackBar 展示七类错误文案，用户知道需要重试；
/// - 「开始下载」回调交由调用方入队并 toast。
library;

import 'package:flutter/material.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/core/error.dart';
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/ui/common/error_views.dart';
import 'package:clipvault/ui/common/preview_card.dart';

/// 清晰度选择 Sheet 内容（也可直接作为 widget 测试宿主）
class QualitySheet extends StatefulWidget {
  const QualitySheet({
    super.key,
    required this.tweet,
    required this.onStartDownload,
    this.onSwitchVideo,
    this.initialVariantIndex = 0,
    this.preferredVariantIndex,
  });

  final TweetMeta tweet;

  /// 「开始下载」回调：选中变体 + 当前视频序号
  final void Function(VideoVariant selected, int videoIndex) onStartDownload;

  /// 多视频切换回调（videoCount>1 时调用方必传；返回重新解析结果）
  final Future<ResolveResult> Function(int videoIndex)? onSwitchVideo;

  final int initialVariantIndex;

  /// 偏好档位计算（入参为目标视频的变体列表，返回默认高亮索引）：
  /// 多视频切换后按新视频的档位重新匹配（如「省流 720p」找 720p 档），
  /// 而非沿用旧视频的索引位置——各视频档位分布不同，同索引会错档。
  final int Function(List<VideoVariant> variants)? preferredVariantIndex;

  @override
  State<QualitySheet> createState() => _QualitySheetState();
}

class _QualitySheetState extends State<QualitySheet> {
  late int _variantIndex;
  int _videoIndex = 0;
  TweetMeta? _switchedTweet;
  bool _switching = false;

  /// 「开始下载」已触发标记：触发后禁用按钮并关闭 Sheet，防连点重复入队
  bool _submitting = false;

  TweetMeta get _currentTweet => _switchedTweet ?? widget.tweet;

  List<VideoVariant> get _variants {
    final group = _currentTweet.variants;
    // 契约已降序；防御性再排（bitrate 大在前）
    final sorted = List<VideoVariant>.of(group)
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return sorted;
  }

  @override
  void initState() {
    super.initState();
    _variantIndex = widget.initialVariantIndex;
  }

  Future<void> _switchVideo(int index) async {
    final resolver = widget.onSwitchVideo;
    if (resolver == null || _switching) return;
    setState(() => _switching = true);
    try {
      final result = await resolver(index);
      if (mounted) {
        setState(() {
          _videoIndex = index;
          _switchedTweet = result.tweet;
          // 偏好档位按新视频的变体列表重新匹配（省流 720p 找 720p 档，
          // 找不到回落 0=最高码率），不再沿用旧索引导致静默错档。
          final variants = result.tweet.variants;
          final preferred = widget.preferredVariantIndex?.call(variants) ?? 0;
          _variantIndex = variants.isEmpty
              ? 0
              : preferred.clamp(0, variants.length - 1);
          _switching = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _switching = false);
        // 切换失败不再静默（用户会以为「没点到」而反复点击）：
        // 保持当前视频不变，但让失败可见、给出可感知的原因。
        final message = error is ParseError
            ? parseErrorMessage(error)
            : AppStrings.errNetworkTimeout;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    }
  }

  /// 「开始下载」：触发即禁用按钮 + 关闭 Sheet（同一变体只入队一次）
  void _startDownload() {
    if (_submitting || _switching) return;
    final variants = _variants;
    if (variants.isEmpty) return;
    setState(() => _submitting = true);
    widget.onStartDownload(
      variants[_variantIndex.clamp(0, variants.length - 1)],
      _videoIndex,
    );
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final variants = _variants;
    final multiVideo =
        _currentTweet.videoCount > 1 && widget.onSwitchVideo != null;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    AppStrings.qualitySheetTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          if (multiVideo)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (var i = 0; i < _currentTweet.videoCount; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('${AppStrings.qualityVideoChip}${i + 1}'),
                        selected: _videoIndex == i,
                        onSelected: (_) => _switchVideo(i),
                      ),
                    ),
                ],
              ),
            ),
          PreviewCard(tweet: _currentTweet),
          Flexible(
            child: _switching
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : variants.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(child: Text(AppStrings.errNotVideoTweet)),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: variants.length,
                        itemBuilder: (context, index) {
                          final v = variants[index];
                          final selected = index == _variantIndex;
                          return ListTile(
                            selected: selected,
                            leading: Icon(
                              selected ? Icons.check_circle : Icons.movie_outlined,
                              color: selected ? scheme.primary : scheme.onSurfaceVariant,
                            ),
                            title: Text(v.qualityLabel),
                            subtitle: Text(
                              '${(v.bitrate / 1000000).toStringAsFixed(2)} ${AppStrings.unitMbps}'
                              ' · ${AppStrings.about} ${formatBytesCompact(v.estimatedBytes)}'
                              ' · ${AppStrings.tagMp4}',
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            ),
                            onTap: () => setState(() => _variantIndex = index),
                          );
                        },
                      ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: FilledButton.icon(
              // 触发后禁用（连点防抖）；空变体/切换中同样不可点
              onPressed: variants.isEmpty || _switching || _submitting
                  ? null
                  : _startDownload,
              icon: const Icon(Icons.download),
              label: const Text(AppStrings.qualityStartDownload),
            ),
          ),
        ],
      ),
    );
  }
}

/// 弹出清晰度 Sheet 的便捷入口
///
/// [initialVariantIndex]：初始高亮档（省流 720p 偏好由调用方按
/// DESIGN §3.2 计算后传入；缺省 0 = 最高码率档）。
/// [preferredVariantIndex]：多视频切换后的偏好重匹配函数（见 QualitySheet）。
Future<void> showQualitySheet(
  BuildContext context, {
  required TweetMeta tweet,
  required void Function(VideoVariant selected, int videoIndex) onStartDownload,
  Future<ResolveResult> Function(int videoIndex)? onSwitchVideo,
  int initialVariantIndex = 0,
  int Function(List<VideoVariant> variants)? preferredVariantIndex,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: QualitySheet(
        tweet: tweet,
        onStartDownload: onStartDownload,
        onSwitchVideo: onSwitchVideo,
        initialVariantIndex: initialVariantIndex,
        preferredVariantIndex: preferredVariantIndex,
      ),
    ),
  );
}
