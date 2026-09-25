import 'package:drift/drift.dart';

/// 下载任务状态的持久化取值（DESIGN §5.3「status TEXT」列的合法值域）。
///
/// 该枚举是 status 列字符串取值的唯一权威来源（按 `name` 与 TEXT 互转）；
/// 引擎（lib/download/download_task.dart）与 UI 应复用本枚举或与其按
/// `name` 互转，不得另行引入平行的字符串常量集合。
enum DownloadStatus {
  queued,
  running,
  paused,
  completed,
  failed,
  canceled,
}

/// 严格解析状态字符串；未知取值抛 [ArgumentError]。
///
/// status 列仅由本 App 写入，正常运行不会触发异常；测试与防御性读取
/// 可改用 [tryParseDownloadStatus]。
DownloadStatus parseDownloadStatus(String name) {
  final parsed = tryParseDownloadStatus(name);
  if (parsed == null) {
    throw ArgumentError.value(name, 'name', '未知的 DownloadStatus 取值');
  }
  return parsed;
}

/// 容错解析状态字符串；null 或未知取值返回 null。
DownloadStatus? tryParseDownloadStatus(String? name) {
  if (name == null) return null;
  for (final status in DownloadStatus.values) {
    if (status.name == name) return status;
  }
  return null;
}

/// 下载记录表（DESIGN §5.3 字段级定义，本项目唯一持久化表）。
///
/// 约定：
/// - [status] 存 [DownloadStatus.name] 字符串；
/// - [tweetJson] 为解析结果元数据快照，历史页离线渲染的依据；
/// - [albumSavedAt] 为 null 表示尚未入相册（历史页「重新保存至相册」入口依据）；
/// - [createdAt]/[updatedAt] 由 drift 以 INTEGER（unix 秒，UTC）存储。
@DataClassName('DownloadRecord')
@TableIndex(name: 'idx_download_records_tweet_id', columns: {#tweetId})
@TableIndex(
  name: 'idx_download_records_status_updated_at',
  columns: {#status, #updatedAt},
)
class DownloadRecords extends Table {
  /// 自增主键。
  IntColumn get id => integer().autoIncrement()();

  /// 推文 ID（16~20 位雪花 ID，TEXT 存储），见 §5.3 tweetId (idx)。
  TextColumn get tweetId => text()();

  /// 选中变体的直链（含签名参数，会过期）。
  TextColumn get variantUrl => text()();

  /// 容器类型，当前恒为 'mp4'（HLS 裁剪理由见 §12.9）。
  TextColumn get contentType => text()();

  /// 码率 bps，如 2176000。
  IntColumn get bitrate => integer()();

  /// 宽（像素），可空——响应无分辨率字段时由 URL 正则提取。
  IntColumn get width => integer().nullable()();

  /// 高（像素），可空。
  IntColumn get height => integer().nullable()();

  /// 清晰度标签，如 '720p (HD)'。
  TextColumn get qualityLabel => text()();

  /// 状态取值见 [DownloadStatus]。
  TextColumn get status => text()();

  /// 总字节数；未知（未收到 content-length）为 null。
  IntColumn get bytesTotal => integer().nullable()();

  /// 已完成字节数（断点续传基准）。
  IntColumn get bytesDone => integer().withDefault(const Constant(0))();

  /// 平滑速率 bps（3 秒滑动窗口）。
  IntColumn get speedBps => integer().withDefault(const Constant(0))();

  /// 预计剩余秒数，未知为 null。
  IntColumn get etaSec => integer().nullable()();

  /// 转正后的最终文件路径（appDocuments/downloads/{tweetId}_{bitrate}.mp4）。
  TextColumn get filePath => text().nullable()();

  /// 断点文件路径（同名 .part）；启动恢复扫描依据。
  TextColumn get partPath => text().nullable()();

  /// ParseError/DownloadError 错误码（如 'E02'）；仅 failed 态有意义。
  TextColumn get errorCode => text().nullable()();

  /// 引擎内部已自动重试次数。
  IntColumn get autoRetries => integer().withDefault(const Constant(0))();

  /// 推文元数据快照 JSON（历史页离线渲染缩略图/作者/文案/清晰度）。
  TextColumn get tweetJson => text()();

  /// 入相册时间；null = 未入相册（被拒降级/未保存）。
  DateTimeColumn get albumSavedAt => dateTime().nullable()();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// 更新时间（复合索引 (status, updatedAt) 第二列）。
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}
