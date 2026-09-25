/// 推文预览卡（DESIGN §7.1-2 / §4.2）：
/// 头像 / 昵称 @handle / 正文两行截断 / 封面缩略图（cacheWidth 降采样）/ 时长徽标。
/// 敏感内容（E06）不会走到本组件——解析层已先行阻断且不载缩略图（§8.5 双保险）。
library;

import 'package:flutter/material.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/parse/models.dart';

/// 推文预览卡片
class PreviewCard extends StatelessWidget {
  const PreviewCard({super.key, required this.tweet, this.showText = true});

  final TweetMeta tweet;

  /// 是否展示正文（紧凑模式下可关）
  final bool showText;

  /// 时长格式化 mm:ss / h:mm:ss
  static String formatDuration(int millis) {
    if (millis <= 0) return '0:00';
    final total = millis ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
    return h > 0 ? '$h:$mm:${s.toString().padLeft(2, '0')}' : '$mm:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面：URL 直接渲染 + 降采样解码（§9-11），失败/缺失回落灰底图标
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: tweet.thumbnailUrl.isEmpty
                    ? ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: const Center(child: Icon(Icons.movie_outlined, size: 40)),
                      )
                    : Image.network(
                        tweet.thumbnailUrl,
                        cacheWidth: 640,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => ColoredBox(
                          color: scheme.surfaceContainerHighest,
                          child: const Center(child: Icon(Icons.broken_image_outlined)),
                        ),
                      ),
              ),
              if (tweet.durationMillis > 0)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      formatDuration(tweet.durationMillis),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundImage:
                      tweet.avatarUrl.isEmpty ? null : NetworkImage(tweet.avatarUrl),
                  onBackgroundImageError: tweet.avatarUrl.isEmpty ? null : (_, _) {},
                  child: tweet.avatarUrl.isEmpty
                      ? Text(tweet.userName.isEmpty ? '?' : tweet.userName.characters.first)
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tweet.userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '@${tweet.screenName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                      if (showText && tweet.text.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          tweet.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 最近解析的紧凑预览行（首页内存态卡片，§7.1-1）
class RecentParseTile extends StatelessWidget {
  const RecentParseTile({super.key, required this.tweet, required this.onTap});

  final TweetMeta tweet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 64,
          height: 40,
          child: tweet.thumbnailUrl.isEmpty
              ? ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: const Center(child: Icon(Icons.movie_outlined, size: 18)),
                )
              : Image.network(
                  tweet.thumbnailUrl,
                  cacheWidth: 128,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: const Center(child: Icon(Icons.broken_image_outlined, size: 18)),
                  ),
                ),
        ),
      ),
      title: Text(
        tweet.text.isEmpty ? '@${tweet.screenName}' : tweet.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('@${tweet.screenName} · ${PreviewCard.formatDuration(tweet.durationMillis)}'),
      onTap: onTap,
    );
  }
}

/// 供质量 Sheet 复用的体积格式化（约 24.5 MB）
String formatBytesCompact(int bytes) {
  if (bytes <= 0) return '0 ${AppStrings.unitMB}';
  const unit = 1024 * 1024;
  final mb = bytes / unit;
  if (mb >= 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  return '${mb.toStringAsFixed(1)} ${AppStrings.unitMB}';
}
