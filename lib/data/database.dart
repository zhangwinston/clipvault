import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'tables.dart';

part 'database.g.dart';

/// 应用数据库（DESIGN §5.3/§5.5）。
///
/// executor 一律构造注入（§9-3 决策）：
/// - 生产：[AppDatabase.production]（[LazyDatabase] 惰性打开，
///   首次查询才建连，传入应用文档目录下的 xdown.db）；
/// - 测试：`AppDatabase(DatabaseConnection(NativeDatabase.memory(),
///   closeStreamsSynchronously: true))`（见 test/data/history_repository_test.dart）。
@DriftDatabase(tables: [DownloadRecords])
class AppDatabase extends _$AppDatabase {
  /// 以注入的 [executor] 打开数据库（生产/测试唯一入口，禁止内部自建连接）。
  AppDatabase(super.executor);

  /// 生产构造：惰性打开 [file]（约定为 `appDocuments/xdown.db`，§5.5）。
  ///
  /// 父目录不存在时自动创建；本类不解析平台路径（保持零 platform import，
  /// 路径由调用方经 path_provider 等方式提供）。
  factory AppDatabase.production(File file) {
    // drift 2.35 的 NativeDatabase 无 lazyDatabase 静态成员；惰性建连应使用
    // drift.dart 顶层导出的 [LazyDatabase]（首次 ensureOpen 才调用 opener）。
    return AppDatabase(
      LazyDatabase(() async {
        final dir = file.parent;
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        return NativeDatabase(file);
      }),
    );
  }

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // v2：新增 activeMs（累计活跃毫秒，净时长口径的已用时间）。
            await m.addColumn(
                downloadRecords, downloadRecords.activeMs);
          }
        },
      );
}

/// 便捷扩展：记录行直接读取枚举状态。
//
// 生成的 DownloadRecord 行类位于本库（database.g.dart），扩展随库定义
// （tables.dart 仅存表定义与枚举，避免表文件依赖生成物造成循环导入）。
extension DownloadRecordStatusX on DownloadRecord {
  /// 当前状态枚举（等价于 tables.parseDownloadStatus）。
  DownloadStatus get statusEnum => parseDownloadStatus(status);
}
