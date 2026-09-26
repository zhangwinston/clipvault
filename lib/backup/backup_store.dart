/// 历史备份存储抽象（DESIGN §4.7「卸载重装保留历史」）。
///
/// 三层方案中的②（本地自动备份）：把历史快照 JSON 写到**卸载后仍保留**
/// 的位置——Android 用公共 Downloads/ClipVault（MediaStore，同包名重装
/// 后 owner 复联免权限读回，见 MainActivity.kt）；iOS/其他平台回落应用
/// Documents 目录（iOS 侧经 Info.plist UIFileSharingEnabled 在「文件」
/// App 可见，且 iCloud 整机备份自动覆盖；方案①云恢复的兜底）。
library;

import 'package:flutter/services.dart';

import 'documents_backup_store.dart';

export 'documents_backup_store.dart';

abstract class BackupStore {
  /// 平台是否支持跨卸载保留（Android API 29+ / iOS 恒 true）。
  Future<bool> get isSupported;

  /// 全量写入备份 JSON；失败返回 false（调用方静默降级，备份是增强能力）。
  Future<bool> write(String json);

  /// 读回备份 JSON；不存在/不可读返回 null。
  Future<String?> read();

  /// 按文件名回查相册视频绝对路径（Android 专属能力；其他平台返回 null）。
  /// 文件名约定 {tweetId}_{bitrate}.mp4（引擎转正命名，§4.3）。
  Future<String?> findVideoPathByName(String name);
}

/// Android 实现：经 MainActivity 注册的 clipvault/backup 通道操作
/// MediaStore Downloads（API <29 通道报不支持，isSupported=false）。
class AndroidMediaStoreBackupStore implements BackupStore {
  AndroidMediaStoreBackupStore();

  static const MethodChannel _channel = MethodChannel('clipvault/backup');

  @override
  Future<bool> get isSupported async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> write(String json) async {
    try {
      return await _channel.invokeMethod<bool>('writeBackup', {'json': json}) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> read() async {
    try {
      return await _channel.invokeMethod<String>('readBackup');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> findVideoPathByName(String name) async {
    try {
      return await _channel.invokeMethod<String>('findVideoPathByName', {'name': name});
    } catch (_) {
      return null;
    }
  }
}

/// 按平台选择实现（生产入口；测试经 Provider 注入假实现）。
///
/// Android 走 MediaStore 公共 Downloads（跨卸载保留）；其余平台 Documents
/// 文件（iOS 经「文件」App 可见 + iCloud 整机备份覆盖）。
BackupStore defaultBackupStoreForPlatform(TargetPlatform platform) {
  if (platform == TargetPlatform.android) {
    return AndroidMediaStoreBackupStore();
  }
  return DocumentsBackupStore();
}
