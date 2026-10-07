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
  /// 最近一次操作的失败原因（诊断透出用：实现方在 catch / 假值路径
  /// 赋值，BackupService.exportNow 失败时带上 UI，2026-10-07）。
  Object? lastError;

  /// 平台是否支持跨卸载保留（Android API 29+ / iOS 恒 true）。
  Future<bool> get isSupported;

  /// 全量写入备份 JSON；失败返回 false（调用方静默降级，备份是增强能力）。
  Future<bool> write(String json);

  /// 读回备份 JSON；不存在/不可读返回 null。
  Future<String?> read();

  /// SAF 兜底：弹系统文件选择器读用户选中的备份（跨卸载后旧备份
  /// 所有权不归属新安装时的救回通道；用户取消/不支持返回 null）。
  /// 默认空实现（Android 覆写；iOS/桌面暂无）。
  Future<String?> pickAndRead() async => null;

  /// 申请相册视频读取权限（Android 重装恢复场景：Movies/ClipVault 的
  /// 已下载视频与备份 JSON 同为「孤儿」，无权限对重装后的 App 不可见，
  /// 需 READ_MEDIA_VIDEO / READ_EXTERNAL_STORAGE 运行时授权后回查路径）。
  /// 其他平台无此概念，恒 true（不需要也不弹窗）。
  Future<bool> requestVideoReadPermission() async => true;

  /// 按文件名回查相册视频绝对路径（Android 专属能力；其他平台返回 null）。
  /// 文件名约定 {tweetId}_{bitrate}.mp4（引擎转正命名，§4.3）。
  Future<String?> findVideoPathByName(String name);
}

/// Android 实现：经 MainActivity 注册的 clipvault/backup 通道操作
/// MediaStore Downloads（API <29 通道报不支持，isSupported=false）。
class AndroidMediaStoreBackupStore implements BackupStore {
  AndroidMediaStoreBackupStore();

  static const MethodChannel _channel = MethodChannel('clipvault/backup');

  // implements 下抽象类的具体字段仅是接口（getter/setter 对），需自备存储
  @override
  Object? lastError;

  @override
  Future<bool> get isSupported async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (e) {
      lastError = e;
      return false;
    }
  }

  @override
  Future<bool> write(String json) async {
    lastError = null;
    try {
      final ok = await _channel.invokeMethod<bool>('writeBackup', {'json': json}) ?? false;
      if (!ok) lastError = '原生写入返回失败（详见 logcat ClipVaultBackup）';
      return ok;
    } catch (e) {
      lastError = e;
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

  @override
  Future<String?> pickAndRead() async {
    try {
      return await _channel.invokeMethod<String>('pickAndReadBackup');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> requestVideoReadPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestVideoReadPermission') ??
          false;
    } catch (_) {
      return false;
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
