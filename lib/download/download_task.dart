/// 下载任务实体与状态机。
///
/// 契约依据 DESIGN §4.3（任务状态机）与 §5.3（DownloadRecords 字段级定义）：
/// - 状态：`queued → running → (paused | completed | failed | canceled)`，幂等转移；
/// - [DownloadFailureKind] 语义对齐 DESIGN §5.2 的 DownloadError 三分类；
/// - 字段与 drift 表 DownloadRecords 一一对应，便于持久层（S4）直接映射。
///
/// 本文件零 platform import、零第三方依赖（DESIGN §9-8：业务层纯 Dart）。
library;

/// 任务状态（与 drift DownloadRecords.status 列的取值一致）。
enum DownloadStatus { queued, running, paused, completed, failed, canceled }

/// 失败分类。
///
/// 语义对齐 DESIGN §5.2 `DownloadError { retryable, permanent(reason), urlExpired }`：
/// - [retryable]：网络类错误，指数退避 3 次后仍失败，UI 提供"一键重试"；
/// - [permanent]：404 等，重试无意义；
/// - [urlExpired]：403/410 直链签名过期且自动重解析刷新未能挽回，
///   "一键重试"会再次触发 URL 刷新（引擎在手动重试时重置刷新标记）。
enum DownloadFailureKind { retryable, permanent, urlExpired }

/// 同业务键（tweetId + bitrate）重复入队异常。
///
/// 断点文件路径由 `{tweetId}_{bitrate}` 确定性生成：同键的两个未终结
/// （queued/running/paused）任务会以 append 模式并发交错写同一 .part，
/// 字节流损坏且转正阶段竞态。故引擎 [DownloadEngine.enqueue] 对未终结
/// 任务做业务键去重，命中即抛本异常（携带既有任务 id，供上层提示
/// 「已在队列中」并定位既有任务）；终态（completed/failed/canceled）
/// 不占用业务键，同键可重新下载。
class DuplicateActiveTaskException implements Exception {
  DuplicateActiveTaskException({
    required this.tweetId,
    required this.bitrate,
    required this.existingTaskId,
  });

  /// 业务键：推文 ID。
  final String tweetId;

  /// 业务键：码率（bps）。
  final int bitrate;

  /// 已存在的未终结任务 id（UI 可据此定位既有任务）。
  final String existingTaskId;

  @override
  String toString() =>
      'DuplicateActiveTaskException(tweetId: $tweetId, bitrate: $bitrate, '
      'existingTaskId: $existingTaskId)';
}

/// 合法状态转移表（不含幂等自环，自环恒合法）。
///
/// - queued → running：调度启动；
/// - queued → paused：用户暂停排队任务，或 429 全队列冷却（DESIGN §4.3）；
/// - running → paused：用户暂停 / 冷却，保留 .part；
/// - running → completed / failed / canceled：终局；
/// - paused → queued：恢复 / 冷却结束自动回归队列；
/// - paused → canceled：排队与暂停态均可取消；
/// - failed → queued：一键重试（重置 autoRetries 与 urlRefreshed）；
/// - canceled → queued：重新下载；
/// - completed 为硬终态（仅幂等自环）。
const Map<DownloadStatus, Set<DownloadStatus>> kTransitionTable = {
  DownloadStatus.queued: {
    DownloadStatus.running,
    DownloadStatus.paused,
    DownloadStatus.failed,
    DownloadStatus.canceled,
  },
  DownloadStatus.running: {
    DownloadStatus.paused,
    DownloadStatus.completed,
    DownloadStatus.failed,
    DownloadStatus.canceled,
  },
  DownloadStatus.paused: {
    DownloadStatus.queued,
    DownloadStatus.canceled,
    DownloadStatus.failed,
  },
  DownloadStatus.failed: {
    DownloadStatus.queued,
    DownloadStatus.canceled,
  },
  DownloadStatus.completed: <DownloadStatus>{},
  DownloadStatus.canceled: {
    DownloadStatus.queued,
  },
};

/// 是否为合法转移；`from == to` 视为幂等 no-op，恒合法。
bool isLegalTransition(DownloadStatus from, DownloadStatus to) {
  if (from == to) return true;
  return kTransitionTable[from]?.contains(to) ?? false;
}

/// 下载任务不可变快照。
///
/// 引擎内部以"替换整条记录"的方式演进状态，广播与持久化的永远是
/// 自洽快照（不可变对象天然异步安全，UI 可直接渲染）。
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.tweetId,
    required this.variantUrl,
    required this.contentType,
    required this.bitrate,
    required this.qualityLabel,
    required this.createdAt,
    this.width,
    this.height,
    this.status = DownloadStatus.queued,
    this.bytesTotal,
    this.bytesDone = 0,
    this.speedBps = 0,
    this.etaSec,
    this.filePath,
    this.partPath,
    this.failureKind,
    this.errorMessage,
    this.autoRetries = 0,
    this.urlRefreshed = false,
    this.pausedForCooldown = false,
    this.tweetJson,
    this.albumSavedAt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  /// 引擎侧唯一标识（新建任务由 [DownloadTask.create] 生成递增 id；
  /// 持久层可将其映射到 DownloadRecords 主键）。
  final String id;

  // ---- 变体描述（来自解析层 TweetMeta.variants，由 UI 层组装） ----
  final String tweetId;

  /// video.twimg.com 直链（含签名参数，会过期；403/410 时经重解析回调刷新）。
  final String variantUrl;
  final String contentType; // 'mp4'
  final int bitrate; // bps
  final int? width;
  final int? height;
  final String qualityLabel; // 如 '720p (HD)'
  final Map<String, Object?>? tweetJson; // 元数据快照（历史页离线渲染）

  // ---- 运行态（与 §5.3 列一致） ----
  final DownloadStatus status;
  final int? bytesTotal;
  final int bytesDone;
  final int speedBps;
  final int? etaSec;

  /// 终转正路径（{tweetId}_{bitrate}.mp4）；完成前为 null。
  final String? filePath;

  /// 断点文件路径（{tweetId}_{bitrate}.part）；引擎首跑时分配。
  final String? partPath;
  final DownloadFailureKind? failureKind;
  final String? errorMessage;

  /// 已消耗的自动重试次数（指数退避计数，DESIGN §4.3）。
  final int autoRetries;

  /// 403/410 自动重解析刷新是否已用过一次（每任务一次，手动重试时重置）。
  final bool urlRefreshed;

  /// 是否因 429 全队列冷却而被暂停（冷却结束自动回归 queued；
  /// 用户手动暂停的任务此标记为 false，不受冷却恢复影响）。
  final bool pausedForCooldown;

  /// 入册时间；null = 未入相册（历史页"重新保存至相册"入口依据，§4.4）。
  final DateTime? albumSavedAt;

  final DateTime createdAt;
  final DateTime updatedAt;

  static int _seq = 0;

  /// 创建新任务（id 由引擎侧递增序列生成，测试可预期）。
  factory DownloadTask.create({
    required String tweetId,
    required String variantUrl,
    required int bitrate,
    required String qualityLabel,
    String contentType = 'mp4',
    int? width,
    int? height,
    Map<String, Object?>? tweetJson,
    String? id,
    DateTime? createdAt,
  }) {
    return DownloadTask(
      id: id ?? 'task_${_seq++}',
      tweetId: tweetId,
      variantUrl: variantUrl,
      contentType: contentType,
      bitrate: bitrate,
      width: width,
      height: height,
      qualityLabel: qualityLabel,
      tweetJson: tweetJson,
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  /// 测试辅助：重置 id 序列，保证用例间确定性。
  static void resetIdSequenceForTest() => _seq = 0;

  /// completed 为唯一硬终态（failed/canceled 均可重试或重新入队）。
  bool get isCompleted => status == DownloadStatus.completed;

  /// UI 分区用：是否离开活动区（进行中/队列/暂停）。
  bool get isSettled =>
      status == DownloadStatus.completed ||
      status == DownloadStatus.failed ||
      status == DownloadStatus.canceled;

  /// 进度百分比 0.0~1.0；总量未知时为 null。
  double? get progress =>
      bytesTotal != null && bytesTotal! > 0 ? bytesDone / bytesTotal! : null;

  /// 状态转移（非法且非幂等时抛 [StateError]，用于在编码期暴露状态机 bug）。
  DownloadTask withStatus(DownloadStatus to, {DateTime? at}) {
    if (!isLegalTransition(status, to)) {
      throw StateError('非法状态转移: ${status.name} -> ${to.name} (task $id)');
    }
    if (status == to) return this;
    return copyWith(status: to, updatedAt: at);
  }

  /// copyWith 哨兵：区分"参数省略（保持原值）"与"显式传 null（清空）"。
  static const Object _kUnset = _Unset();

  /// copyWith。
  ///
  /// - 省略参数 = 保持原值；
  /// - 显式传 null（仅限可空字段：etaSec/failureKind/errorMessage/
  ///   albumSavedAt）= 清空——albumSavedAt 置空语义（DESIGN §4.4）与
  ///   retry 清空失败信息依赖此行为。
  DownloadTask copyWith({
    String? variantUrl,
    DownloadStatus? status,
    int? bytesTotal,
    int? bytesDone,
    int? speedBps,
    Object? etaSec = _kUnset,
    String? filePath,
    String? partPath,
    Object? failureKind = _kUnset,
    Object? errorMessage = _kUnset,
    int? autoRetries,
    bool? urlRefreshed,
    bool? pausedForCooldown,
    Object? albumSavedAt = _kUnset,
    DateTime? updatedAt,
  }) {
    return DownloadTask(
      id: id,
      tweetId: tweetId,
      variantUrl: variantUrl ?? this.variantUrl,
      contentType: contentType,
      bitrate: bitrate,
      width: width,
      height: height,
      qualityLabel: qualityLabel,
      tweetJson: tweetJson,
      status: status ?? this.status,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      bytesDone: bytesDone ?? this.bytesDone,
      speedBps: speedBps ?? this.speedBps,
      etaSec: etaSec == _kUnset ? this.etaSec : etaSec as int?,
      filePath: filePath ?? this.filePath,
      partPath: partPath ?? this.partPath,
      failureKind: failureKind == _kUnset
          ? this.failureKind
          : failureKind as DownloadFailureKind?,
      errorMessage: errorMessage == _kUnset
          ? this.errorMessage
          : errorMessage as String?,
      autoRetries: autoRetries ?? this.autoRetries,
      urlRefreshed: urlRefreshed ?? this.urlRefreshed,
      pausedForCooldown: pausedForCooldown ?? this.pausedForCooldown,
      albumSavedAt: albumSavedAt == _kUnset
          ? this.albumSavedAt
          : albumSavedAt as DateTime?,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  @override
  String toString() =>
      'DownloadTask($id ${status.name} $bytesDone/${bytesTotal ?? '?'} '
      'retries=$autoRetries refreshed=$urlRefreshed)';
}

/// copyWith 哨兵类型（私有，仅用于区分"省略"与"传 null"）。
class _Unset {
  const _Unset();
}
