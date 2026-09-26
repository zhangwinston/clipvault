/// 相册保存：接口化隔离平台插件（DESIGN §4.4 / §9-8）。
///
/// - 抽象 [GallerySaver] 供下载引擎与 UI 依赖（纯 Dart，可 mock）；
/// - 生产实现 [GalGallerySaver] 封装 gal 2.3.3：`putVideo(path, album: 'ClipVault')`；
/// - 权限时序：仅在"下载完成首次入册"时机按需请求（iOS add-only；
///   Android 29+ MediaStore 零运行时权限）；
/// - 被拒完整降级路径（DESIGN §4.4，评委 3 肯定的独有路径）：
///   返回 [GallerySaveOutcome.permissionDenied]，视频仍保留在应用沙盒，
///   [GallerySaveResult.savedAt] 为 null → 持久层 albumSavedAt 置空 →
///   历史页出现"重新保存至相册"入口；任务不因拒绝而中断。
library;

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';

/// 保存结果分类。
enum GallerySaveOutcome {
  /// 成功入册（savedAt 非空）。
  saved,

  /// 权限被拒：降级沙盒保存，albumSavedAt 置空（DESIGN §4.4）。
  permissionDenied,

  /// 其他失败（空间不足/格式不支持/未知异常）：同样降级沙盒 + albumSavedAt 置空。
  failed,
}

/// 单次入册结果。
class GallerySaveResult {
  const GallerySaveResult({required this.outcome, this.savedAt});

  final GallerySaveOutcome outcome;

  /// 仅 [GallerySaveOutcome.saved] 时非空；其余一律 null（albumSavedAt 置空语义）。
  final DateTime? savedAt;

  bool get isSaved => outcome == GallerySaveOutcome.saved;
}

/// 相册保存抽象。引擎与 UI 只依赖此接口；测试注入 fake。
abstract class GallerySaver {
  /// 将 [path] 指向的视频保存进相册 [album]。
  ///
  /// 永不抛异常：一切失败都收敛为 [GallerySaveResult] 返回值，
  /// 保证"任务不因入册失败而中断"。
  Future<GallerySaveResult> saveVideo({required String path, required String album});
}

/// 生产实现：gal 2.3.3（BSD-3，verified publisher，LocalSend 同款）。
class GalGallerySaver implements GallerySaver {
  const GalGallerySaver();

  @override
  Future<GallerySaveResult> saveVideo({
    required String path,
    required String album,
  }) async {
    try {
      // 权限按需请求（首次保存时才触发，§8.1"首屏零索取"）。
      // hasAccess(toAlbum: true) 对应自定义相册写入权限。
      if (!await Gal.hasAccess(toAlbum: true)) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          return const GallerySaveResult(outcome: GallerySaveOutcome.permissionDenied);
        }
      }
      await Gal.putVideo(path, album: album);
      return GallerySaveResult(
        outcome: GallerySaveOutcome.saved,
        savedAt: DateTime.now(),
      );
    } on GalException catch (e) {
      if (e.type == GalExceptionType.accessDenied) {
        return const GallerySaveResult(outcome: GallerySaveOutcome.permissionDenied);
      }
      return const GallerySaveResult(outcome: GallerySaveOutcome.failed);
    } catch (_) {
      // 任何未知异常都不上抛：沙盒副本仍然有效，历史页提供重存入口。
      return const GallerySaveResult(outcome: GallerySaveOutcome.failed);
    }
  }
}

/// 相册权限预解释包装器（P1-8）：首次真正触发系统权限弹窗之前，
/// 先弹一个应用内说明（为什么需要相册权限、拒绝后的降级路径），
/// 避免用户在毫无上下文的下载完成瞬间面对系统弹窗习惯性拒绝。
///
/// 判定「即将触发系统弹窗」= 当前无相册权限且从未解释过；
/// 解释标记由调用方持久化（SharedPreferences）。
class PreExplainGallerySaver implements GallerySaver {
  PreExplainGallerySaver({
    required this.inner,
    required this.contextResolver,
    required this.hasExplained,
    required this.markExplained,
    required this.explainTitle,
    required this.explainBody,
    required this.explainConfirm,
  });

  final GallerySaver inner;

  /// 页面上下文解析（全局 navigatorKey；无可用上下文时跳过解释）。
  final BuildContext? Function() contextResolver;

  final Future<bool> Function() hasExplained;
  final Future<void> Function() markExplained;

  /// 弹窗文案（由调用方注入，保持本文件零用户文案依赖）。
  final String explainTitle;
  final String explainBody;
  final String explainConfirm;

  @override
  Future<GallerySaveResult> saveVideo({
    required String path,
    required String album,
  }) async {
    try {
      final needsSystemPrompt = !await Gal.hasAccess(toAlbum: true);
      final explained = await hasExplained();
      final context = contextResolver();
      if (needsSystemPrompt && !explained && context != null && context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(explainTitle),
            content: Text(explainBody),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(explainConfirm),
              ),
            ],
          ),
        );
        await markExplained();
      }
    } catch (_) {
      // 解释层任何失败都不阻断保存主流程。
    }
    return inner.saveVideo(path: path, album: album);
  }
}
