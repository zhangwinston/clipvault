/// Documents 目录备份实现（iOS/macOS/桌面/宿主测试）。
///
/// Android 走 MediaStore 公共 Downloads（卸载保留，AndroidMediaStoreBackupStore）；
/// 其余平台没有跨卸载的公共位置，回落应用 Documents：
/// - iOS：Info.plist 已开 UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace，
///   Documents 在「文件」App 可见（用户可手动抄送到 iCloud Drive），
///   且 iCloud 整机备份自动覆盖——配合方案①云恢复已是 iOS 侧最优解。
/// - findVideoPathByName 无相册回查能力，恒 null（导入记录的 filePath 置空，
///   历史元数据仍完整恢复，重新保存至相册入口照常可用）。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'backup_store.dart';

class DocumentsBackupStore implements BackupStore {
  DocumentsBackupStore();

  static const String _fileName = 'clipvault_backup.json';

  Future<File> _resolve() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  @override
  Future<bool> get isSupported async => true;

  @override
  Future<bool> write(String json) async {
    try {
      final file = await _resolve();
      await file.parent.create(recursive: true);
      await file.writeAsString(json, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> read() async {
    try {
      final file = await _resolve();
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> findVideoPathByName(String name) async => null;
}
