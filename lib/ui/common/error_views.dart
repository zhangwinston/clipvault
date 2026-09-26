/// 七类 ParseError 一物一视图（DESIGN §6.6 / §7 全局）。
///
/// - 每类错误独占一个视图：图标 + 主文案（+ 补充文案）+ 动作按钮；
/// - 网络类（E02/E03）带一键重试；
/// - E06 受限内容不加载任何缩略图（NSFW 双保险）；
/// - 下载侧 errorCode 字符串复用同一文案映射（§5.3 errorCode 列）。
library;

import 'package:flutter/material.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/core/error.dart';

/// 解析错误视图
class ParseErrorView extends StatelessWidget {
  const ParseErrorView({super.key, required this.error, this.onRetry});

  final ParseError error;

  /// 网络类错误的重试回调
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = _specFor(error);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(spec.icon, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    spec.message,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (spec.hint != null) ...[
              const SizedBox(height: 6),
              Text(
                spec.hint!,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
            if (spec.retryable && onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text(AppStrings.actionRetry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorSpec {
  const _ErrorSpec(this.icon, this.message, {this.hint, this.retryable = false});

  final IconData icon;
  final String message;
  final String? hint;
  final bool retryable;
}

_ErrorSpec _specFor(ParseError error) {
  // 穷举 sealed 七类（编译期强制，新增类型即编译失败）
  return switch (error) {
    UrlInvalid() => _ErrorSpec(
        Icons.link_off,
        AppStrings.errUrlInvalid,
        hint: AppStrings.errUrlInvalidHint,
      ),
    NetworkTimeout() => _ErrorSpec(
        Icons.wifi_off,
        AppStrings.errNetworkTimeout,
        retryable: true,
      ),
    RateLimited() => _ErrorSpec(
        Icons.speed,
        AppStrings.errRateLimited,
        hint: AppStrings.errRateLimitedHint,
        retryable: true,
      ),
    TweetNotFound() => _ErrorSpec(
        Icons.search_off,
        AppStrings.errTweetNotFound,
        hint: AppStrings.errTweetNotFoundHint,
      ),
    NotVideoTweet() => _ErrorSpec(
        Icons.movie_filter_outlined,
        AppStrings.errNotVideoTweet,
      ),
    RestrictedContent() => _ErrorSpec(
        Icons.block,
        AppStrings.errRestrictedContent,
      ),
    EndpointDrift() => _ErrorSpec(
        Icons.dns_outlined,
        AppStrings.errEndpointDrift,
        hint: AppStrings.errEndpointDriftHint,
        // 配置刷新可能成功/瞬时结构异常 → 可重试，避免最新版用户走进
        // 「请升级 App 版本」的死胡同（自愈链路在 remoteUrl 接线前，
        // 重试是用户侧唯一出路）。
        retryable: true,
      ),
  };
}

/// 解析错误 → 主文案（供清晰度 Sheet 多视频切换失败等非视图场景复用，
/// 与 ParseErrorView 同源，避免两处文案漂移）。
String parseErrorMessage(ParseError error) => _specFor(error).message;

/// 下载任务失败的 errorCode → 展示文案（§5.3 errorCode 存 ParseError/DownloadError 码）。
///
/// 两个取值域并存（写入侧见 RepoDownloadStore.upsert）：
/// - 解析域契约码 'E01'~'E07'（启动恢复/历史遗留行）；
/// - 引擎侧 DownloadFailureKind.name（'retryable'/'permanent'/'urlExpired'），
///   分别对应网络退避耗尽 / 不可恢复（如 404）/ 直链过期（重试会自动刷新链接）；
/// 未知值回落通用「下载失败」。
String downloadErrorMessage(String? errorCode) {
  switch (errorCode) {
    case 'E01':
      return AppStrings.errUrlInvalid;
    case 'E02':
      return AppStrings.errNetworkTimeout;
    case 'E03':
      return AppStrings.errRateLimited;
    case 'E04':
      return AppStrings.errTweetNotFound;
    case 'E05':
      return AppStrings.errNotVideoTweet;
    case 'E06':
      return AppStrings.errRestrictedContent;
    case 'E07':
      return AppStrings.errEndpointDrift;
    case 'retryable':
      return AppStrings.errNetworkTimeout;
    case 'urlExpired':
      return AppStrings.errDownloadUrlExpired;
    case 'permanent':
      return AppStrings.errDownloadPermanent;
    default:
      return AppStrings.errDownloadFailed;
  }
}
