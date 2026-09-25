/// 下载任务行 + UI 任务数据（TaskItem）+ 下载命令抽象与 Riverpod 装配。
///
/// 本文件是 UI 层与持久层/引擎层的唯一接缝：
/// - [TaskItem] 从 drift 记录（§5.3 DownloadRecords）映射为纯展示模型；
/// - [DownloadCommands] 是 UI 面向的命令接口，测试以假实现 override；
/// - 引擎任务 id（String）与记录行 id（int）的桥接约定：`rec_{rowId}`；
/// - [RepoDownloadStore] 把引擎状态回写 drift（DownloadStore 接缝，§4.3）。
///
/// 注：tables.dart 与 download_task.dart 各自定义了同名 DownloadStatus 枚举
/// （S4/S5 并行产物），本文件以 `tbl.`/`dt.` 前缀隔离，跨侧仅按 `name` 互转。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show LazyDatabase, Value;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/data/database.dart';
import 'package:clipvault/data/history_repository.dart';
import 'package:clipvault/data/tables.dart' as tbl;
import 'package:clipvault/download/download_engine.dart';
import 'package:clipvault/download/download_task.dart' as dt;
import 'package:clipvault/download/gallery_saver.dart';
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/settings/settings_controller.dart';
import 'package:clipvault/ui/common/error_views.dart';
import 'package:path_provider/path_provider.dart';

/// UI 任务展示模型（从 DownloadRecord 映射；tweetJson 快照离线渲染历史，§4.5）
class TaskItem {
  const TaskItem({
    required this.id,
    required this.tweetId,
    required this.status,
    required this.qualityLabel,
    required this.bytesDone,
    required this.speedBps,
    required this.createdAt,
    this.variantUrl = '',
    this.bytesTotal,
    this.etaSec,
    this.errorCode,
    this.filePath,
    this.albumSavedAt,
    this.tweetJson,
  });

  /// drift 行主键（引擎侧 id 为 'rec_{id}'）
  final int id;
  final String tweetId;
  final tbl.DownloadStatus status;
  final String qualityLabel;
  final String variantUrl;
  final int? bytesTotal;
  final int bytesDone;
  final int speedBps;
  final int? etaSec;
  final String? errorCode;
  final String? filePath;
  final DateTime? albumSavedAt;
  final String? tweetJson;
  final DateTime createdAt;

  bool get isActive =>
      status == tbl.DownloadStatus.running || status == tbl.DownloadStatus.paused;
  bool get isQueued => status == tbl.DownloadStatus.queued;
  bool get isFailed =>
      status == tbl.DownloadStatus.failed || status == tbl.DownloadStatus.canceled;
  bool get isHistory => status == tbl.DownloadStatus.completed;

  /// 历史条目：未入相册且本地文件在 → 出「重新保存至相册」入口（§4.4）
  bool get needsResave => isHistory && albumSavedAt == null && filePath != null;

  double? get progressRatio {
    final total = bytesTotal;
    if (total == null || total <= 0) return null;
    return (bytesDone / total).clamp(0.0, 1.0);
  }

  /// tweetJson 快照解析出的展示元数据（缺失/损坏时回落 null，不抛异常）
  Map<String, dynamic>? get _meta {
    final raw = tweetJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // 快照格式由引擎/入队方写入，解析失败即回落占位文案
    }
    return null;
  }

  String? get thumbUrl {
    final v = _meta?['thumbnailUrl'];
    return v is String && v.isNotEmpty ? v : null;
  }

  String get title {
    final v = _meta?['text'];
    if (v is String && v.trim().isNotEmpty) return v;
    return '${AppStrings.tweetFallbackTitle} $tweetId';
  }

  String? get authorName {
    final v = _meta?['userName'];
    return v is String && v.isNotEmpty ? v : null;
  }
}

/// 入队结果（驱动首页 toast 话术）：
/// - [enqueued]：正常入队（toastEnqueued）；
/// - [duplicate]：同 (tweetId, bitrate) 业务键已有活动任务（taskAlreadyQueued）；
/// - [waitingWifi]：仅 Wi-Fi 偏好开启且当前非 Wi-Fi——行保持 queued 暂缓调度。
enum DownloadEnqueueResult { enqueued, duplicate, waitingWifi }

/// UI 面向的下载命令（测试注入假实现；生产由 [EngineDownloadCommands] 适配）
abstract class DownloadCommands {
  /// 入队新任务（清晰度 Sheet「开始下载」）；结果见 [DownloadEnqueueResult]。
  Future<DownloadEnqueueResult> enqueue({
    required String tweetId,
    required VideoVariant variant,
    required String tweetJson,
  });

  Future<void> pause(int id);
  Future<void> resume(int id);
  Future<void> cancel(int id);

  /// 失败/取消后一键重试
  Future<void> retry(int id);
}

/// 连接类型抽象（仅 Wi-Fi 下载偏好用；生产 connectivity_plus，测试注入假实现）。
abstract class ConnectivityChecker {
  /// 当前是否处于 Wi-Fi 网络。
  Future<bool> get isOnWifi;

  /// Wi-Fi 可用性变化流（恢复 Wi-Fi 时补交挂起任务）。
  Stream<bool> get onWifiChanged;
}

/// 生产实现：connectivity_plus（6.x 起一次连接可命中多种类型，按列表判定）。
class ConnectivityPlusChecker implements ConnectivityChecker {
  @override
  Future<bool> get isOnWifi async =>
      (await Connectivity().checkConnectivity()).contains(ConnectivityResult.wifi);

  @override
  Stream<bool> get onWifiChanged => Connectivity()
      .onConnectivityChanged
      .map((results) => results.contains(ConnectivityResult.wifi));
}

/// 引擎 ↔ drift 双向适配。
///
/// 入队方向：先建行拿 int 主键 → 以 'rec_{rowId}' 构造引擎任务 → enqueue；
/// 回写方向：引擎每次状态演进调用 [RepoDownloadStore.upsert] → apply 回同一行。
///
/// 仅 Wi-Fi 偏好（默认关闭）：偏好开启且当前非 Wi-Fi 时，行落库保持 queued
/// （下载 Tab 等待队列可见），暂不交引擎调度；Wi-Fi 恢复（监听连接流或下次
/// 入队前复查）再补交引擎，期间取消/暂停/继续直接写 drift 行状态。
class EngineDownloadCommands implements DownloadCommands {
  EngineDownloadCommands(
    this._engine,
    this._repo, {
    bool Function()? wifiOnlyEnabled,
    ConnectivityChecker? connectivity,
  })  : _wifiOnlyEnabled = wifiOnlyEnabled ?? _wifiOffByDefault,
        _connectivity = connectivity ?? const _NoopConnectivityChecker() {
    // Wi-Fi 恢复 → 补交挂起任务（订阅随 dispose 取消）
    _wifiSub = _connectivity.onWifiChanged.listen((onWifi) {
      if (onWifi) unawaited(_flushHeld());
    });
  }

  static bool _wifiOffByDefault() => false;

  final DownloadEngine _engine;
  final HistoryRepository _repo;
  final bool Function() _wifiOnlyEnabled;
  final ConnectivityChecker _connectivity;

  /// 因仅 Wi-Fi 偏好挂起、尚未交引擎的行主键集合。
  final Set<int> _heldBack = <int>{};
  StreamSubscription<bool>? _wifiSub;
  bool _flushing = false;

  /// 行主键 → 引擎任务 id
  static String engineIdOf(int rowId) => 'rec_$rowId';

  @override
  Future<DownloadEnqueueResult> enqueue({
    required String tweetId,
    required VideoVariant variant,
    required String tweetJson,
  }) async {
    // 入队前先补交挂起任务（网络可能已恢复但连接流尚未投递）
    await _flushHeld();
    // 业务键去重（第一道防线）：引擎内已有同 (tweetId, bitrate) 未终结任务
    // 直接拒绝，不建行；引擎侧 enqueue 去重（DuplicateActiveTaskException）
    // 作为竞态兜底（第二道防线）。
    for (final existing in _engine.tasks) {
      if (!existing.isSettled &&
          existing.tweetId == tweetId &&
          existing.bitrate == variant.bitrate) {
        return DownloadEnqueueResult.duplicate;
      }
    }
    // 1) 建持久化行（默认值列由 drift 补齐；数据类生成于 database.g.dart）
    final row = await _repo.createTask(DownloadRecordsCompanion.insert(
      tweetId: tweetId,
      variantUrl: variant.url,
      contentType: variant.contentType.name,
      bitrate: variant.bitrate,
      qualityLabel: variant.qualityLabel,
      status: tbl.DownloadStatus.queued.name,
      tweetJson: tweetJson,
      width: Value(variant.width),
      height: Value(variant.height),
    ));
    // 2) 仅 Wi-Fi 偏好开启且当前非 Wi-Fi：行保持 queued 挂起，等待网络恢复
    if (_wifiOnlyEnabled() && !await _connectivity.isOnWifi) {
      _heldBack.add(row.id);
      return DownloadEnqueueResult.waitingWifi;
    }
    // 3) 引擎任务入队（快照转 Map 供引擎透传）
    try {
      _engine.enqueue(_taskFromRow(row));
    } on dt.DuplicateActiveTaskException {
      // 引擎业务键去重命中（与第一道防线间的竞态）：回滚刚建的行
      try {
        await _repo.deleteById(row.id);
      } catch (_) {
        // 回滚失败容忍：遗留行随下次启动恢复收敛
      }
      return DownloadEnqueueResult.duplicate;
    }
    return DownloadEnqueueResult.enqueued;
  }

  @override
  Future<void> pause(int id) async {
    if (_heldBack.contains(id)) {
      // 挂起任务暂停：直接落库（引擎尚不知情），仍留在挂起集等待恢复
      await _repo.updateStatus(id, tbl.DownloadStatus.paused);
      return;
    }
    await asyncCall(() => _engine.pause(engineIdOf(id)));
  }

  @override
  Future<void> resume(int id) async {
    if (_heldBack.contains(id)) {
      await _repo.updateStatus(id, tbl.DownloadStatus.queued);
      // 恢复时若已在 Wi-Fi（或偏好已关）立即补交引擎
      if (!_wifiOnlyEnabled() || await _connectivity.isOnWifi) {
        await _flushHeld();
      }
      return;
    }
    await asyncCall(() => _engine.resume(engineIdOf(id)));
  }

  @override
  Future<void> cancel(int id) async {
    if (_heldBack.remove(id)) {
      // 挂起任务取消：直接落库终态，无需引擎参与
      await _repo.updateStatus(id, tbl.DownloadStatus.canceled);
      return;
    }
    await asyncCall(() => _engine.cancel(engineIdOf(id)));
  }

  @override
  Future<void> retry(int id) =>
      asyncCall(() => _engine.retry(engineIdOf(id)));

  static Future<void> asyncCall(void Function() action) async => action();

  /// 补交挂起任务：queued 行交引擎调度；paused 行留观（resume 时再处理）；
  /// 终态/缺失行移出挂起集。单任务失败不阻断其余补交。
  Future<void> _flushHeld() async {
    if (_flushing || _heldBack.isEmpty) return;
    _flushing = true;
    try {
      for (final id in List<int>.of(_heldBack)) {
        try {
          final row = await _repo.getById(id);
          if (row == null) {
            _heldBack.remove(id);
            continue;
          }
          if (row.status == tbl.DownloadStatus.queued.name) {
            _engine.enqueue(_taskFromRow(row));
            _heldBack.remove(id);
          } else if (row.status != tbl.DownloadStatus.paused.name) {
            _heldBack.remove(id);
          }
        } catch (_) {
          // 单任务补交失败：留在挂起集，下次 Wi-Fi 事件/入队前重试
        }
      }
    } finally {
      _flushing = false;
    }
  }

  /// drift 行 → 引擎任务（入队/补交共用；快照转 Map 供引擎透传）
  dt.DownloadTask _taskFromRow(DownloadRecord row) {
    Map<String, Object?>? snapshot;
    try {
      final decoded = jsonDecode(row.tweetJson);
      if (decoded is Map<String, Object?>) snapshot = decoded;
    } catch (_) {}
    return dt.DownloadTask.create(
      id: engineIdOf(row.id),
      tweetId: row.tweetId,
      variantUrl: row.variantUrl,
      bitrate: row.bitrate,
      qualityLabel: row.qualityLabel,
      contentType: row.contentType,
      width: row.width,
      height: row.height,
      tweetJson: snapshot,
      createdAt: row.createdAt,
    );
  }

  /// 释放连接流订阅（Riverpod onDispose 调用）。
  void dispose() {
    _wifiSub?.cancel();
    _wifiSub = null;
  }
}

/// 空实现：未注入连接检查时的默认（偏好默认关闭，永不触发网络判定）。
class _NoopConnectivityChecker implements ConnectivityChecker {
  const _NoopConnectivityChecker();

  @override
  Future<bool> get isOnWifi async => false;

  @override
  Stream<bool> get onWifiChanged => const Stream<bool>.empty();
}

/// 引擎状态回写 drift（DownloadStore 接缝实现，§4.3；接口定义于 download_engine）
class RepoDownloadStore implements DownloadStore {
  RepoDownloadStore(this._repo);

  final HistoryRepository _repo;

  @override
  void upsert(dt.DownloadTask task) {
    final rowId = int.tryParse(task.id.replaceFirst('rec_', ''));
    if (rowId == null) return;
    final errorCode = task.failureKind == null
        ? const Value<String?>.absent()
        : Value(task.failureKind!.name);
    _repo
        .apply(
          rowId,
          DownloadRecordsCompanion(
            status: Value(task.status.name),
            bytesDone: Value(task.bytesDone),
            bytesTotal: Value(task.bytesTotal),
            speedBps: Value(task.speedBps),
            etaSec: Value(task.etaSec),
            filePath: Value(task.filePath),
            partPath: Value(task.partPath),
            errorCode: errorCode,
            autoRetries: Value(task.autoRetries),
            albumSavedAt: Value(task.albumSavedAt),
            updatedAt: Value(task.updatedAt),
          ),
        )
        .catchError((Object _) => 0);
  }
}

// ---------------------------------------------------------------------------
// Riverpod 装配（真实实现；widget 测试全部 override）
// ---------------------------------------------------------------------------

/// 惰性解析的下载目录句柄。
///
/// path_provider 无同步 API，而 [DownloadEngine] 构造需要 Directory；
/// 引擎实际只在 `_ensureDir` 中先 `exists()`/`create()`（异步，届时已完成
/// 解析）再读 `path` 拼文件名，因此除 exists/create/path/absolute 外的
/// 成员在解析前不可用（引擎不会触达，见 download_engine.dart _ensureDir）。
class ResolvingDirectory implements Directory {
  ResolvingDirectory(this._resolve);

  final Future<Directory> Function() _resolve;
  Directory? _resolved;

  Future<Directory> get _dir async => _resolved ??= await _resolve();

  @override
  Future<bool> exists() async => (await _dir).exists();

  @override
  Future<Directory> create({bool recursive = false}) async =>
      (await _dir).create(recursive: recursive);

  @override
  String get path => _resolved?.path ?? '';

  @override
  Directory get absolute => _resolved?.absolute ?? this;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
      'ResolvingDirectory 该成员要求先经 exists()/create() 触发解析: '
      '${invocation.memberName}',
    );
  }
}

/// 生产数据库：appDocuments 根 xdown.db（DESIGN §5.5 存储布局契约）。
///
/// path_provider 异步解析经 drift 的 [LazyDatabase] 惰性打开——首次查询才
/// 建连（原实现落 systemTemp，OS 清缓存即整库丢失，属生产接线缺陷，已修复；
/// LazyDatabase 由 drift.dart 顶层导出，data/database.dart 生产构造同款用法）。
final Provider<AppDatabase> appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(
    LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      return NativeDatabase(
        File('${dir.path}${Platform.pathSeparator}xdown.db'),
      );
    }),
  );
  ref.onDispose(db.close);
  return db;
});

final Provider<HistoryRepository> historyRepositoryProvider =
    Provider<HistoryRepository>((ref) => HistoryRepository(ref.watch(appDatabaseProvider)));

final Provider<DownloadEngine> downloadEngineProvider = Provider<DownloadEngine>((ref) {
  final engine = DownloadEngine(
    store: RepoDownloadStore(ref.watch(historyRepositoryProvider)),
    gallerySaver: ref.watch(gallerySaverProvider),
    // 下载工件落 appDocuments/downloads（§5.5；异步目录经惰性句柄注入）
    downloadDir: ResolvingDirectory(() async {
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}${Platform.pathSeparator}downloads');
    }),
  );
  // 并发数偏好接线（§5.4 settings.concurrency → engine.concurrency）：
  // 先同步应用已加载值（引擎首建晚于设置加载的场景），
  // 再监听设置流，后续调整即时生效（设置可调 1-3，引擎侧钳制）。
  ref
    ..read(settingsControllerProvider)
        .whenData((settings) => engine.concurrency = settings.concurrency)
    ..listen(settingsControllerProvider, (previous, next) {
      next.whenData((settings) => engine.concurrency = settings.concurrency);
    });
  ref.onDispose(() {
    engine.dispose();
  });
  return engine;
});

final Provider<GallerySaver> gallerySaverProvider =
    Provider<GallerySaver>((_) => const GalGallerySaver());

/// 连接类型注入点（仅 Wi-Fi 偏好用；测试注入假实现离线断言）
final Provider<ConnectivityChecker> connectivityCheckerProvider =
    Provider<ConnectivityChecker>((_) => ConnectivityPlusChecker());

final Provider<DownloadCommands> downloadCommandsProvider =
    Provider<DownloadCommands>((ref) {
  final commands = EngineDownloadCommands(
    ref.watch(downloadEngineProvider),
    ref.watch(historyRepositoryProvider),
    wifiOnlyEnabled: () =>
        ref.read(settingsControllerProvider).value?.wifiOnly ?? false,
    connectivity: ref.watch(connectivityCheckerProvider),
  );
  ref.onDispose(commands.dispose);
  return commands;
});

/// 任务+历史双流合并的 UI 观察口（StreamProvider，§9-1）
final StreamProvider<List<TaskItem>> downloadsWatchProvider =
    StreamProvider<List<TaskItem>>((ref) {
  return ref
      .watch(historyRepositoryProvider)
      .watchAll()
      .map((rows) => rows.map(mapRecordToTaskItem).toList(growable: false));
});

/// 429 全队列冷却观察口（引擎 notices：started 携带截止时刻 / ended 置空）
final StreamProvider<DateTime?> coolingProvider =
    StreamProvider<DateTime?>((ref) {
  return ref.watch(downloadEngineProvider).notices.map<DateTime?>((notice) {
    return notice.kind == EngineNoticeKind.rateLimitCooldownStarted
        ? notice.cooldownUntil
        : null;
  });
});

/// drift 记录 → TaskItem 映射（字段与可空性按 DESIGN §5.3）；
/// 公开供历史详情页 watchById 实时流复用（同源映射，避免两处漂移）。
TaskItem mapRecordToTaskItem(DownloadRecord r) => TaskItem(
      id: r.id,
      tweetId: r.tweetId,
      status: tbl.tryParseDownloadStatus(r.status) ?? tbl.DownloadStatus.canceled,
      qualityLabel: r.qualityLabel,
      variantUrl: r.variantUrl,
      bytesTotal: r.bytesTotal,
      bytesDone: r.bytesDone,
      speedBps: r.speedBps,
      etaSec: r.etaSec,
      errorCode: r.errorCode,
      filePath: r.filePath,
      albumSavedAt: r.albumSavedAt,
      tweetJson: r.tweetJson,
      createdAt: r.createdAt,
    );

// ---------------------------------------------------------------------------
// 展示格式化（纯函数）
// ---------------------------------------------------------------------------

/// 字节数 → '24.5 MB' / '1.2 GB'
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 ${AppStrings.unitMB}';
  const mbUnit = 1024 * 1024;
  final mb = bytes / mbUnit;
  if (mb >= 1024) return '${(bytes / (mbUnit * 1024)).toStringAsFixed(2)} GB';
  return '${mb.toStringAsFixed(1)} ${AppStrings.unitMB}';
}

/// 速率 Bps → '2.4 MB/s'
String formatSpeed(int bps) {
  if (bps <= 0) return '0 KB/s';
  const kb = 1024;
  if (bps < kb * kb) return '${(bps / kb).toStringAsFixed(1)} KB/s';
  return '${(bps / (kb * kb)).toStringAsFixed(2)} MB/s';
}

/// ETA 秒 → '约 1:23'（空 → '--'）
String formatEta(int? sec) {
  if (sec == null || sec <= 0) return '--';
  final m = sec ~/ 60;
  final s = sec % 60;
  return '${AppStrings.about} $m:${s.toString().padLeft(2, '0')}';
}

/// 已用时长 → '1:23' / '1:02:03'（PRD 3.3「已用时间」，与速率/ETA 同行展示）
String formatElapsed(Duration elapsed) {
  final d = elapsed.isNegative ? Duration.zero : elapsed;
  String two(int v) => v.toString().padLeft(2, '0');
  final h = d.inHours;
  if (h > 0) return '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  return '${d.inMinutes}:${two(d.inSeconds % 60)}';
}

/// 下载时间 → '2026-09-25 14:30'
String formatDateTime(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

// ---------------------------------------------------------------------------
// 任务行组件
// ---------------------------------------------------------------------------

/// 单任务行：进度 / 速率 / ETA / 操作（§7.1-3）
class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.item,
    this.onOpenDetail,
    this.commands,
  });

  final TaskItem item;

  /// 历史条目点击进入详情（HistoryScreen）
  final VoidCallback? onOpenDetail;

  /// 命令回调来源（空则只读展示，测试/预览用）
  final DownloadCommands? commands;

  @override
  Widget build(BuildContext context) {
    if (item.isHistory) return _historyRow(context);
    return _activeRow(context);
  }

  Widget _activeRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = item.progressRatio;
    final percent = ratio == null ? '--' : '${(ratio * 100).toInt()}%';
    return ListTile(
      leading: _thumb(item.thumbUrl),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text('${item.qualityLabel} · ${item.statusLabel}'),
          const SizedBox(height: 4),
          // 百分比与进度条同行独立展示（§7.1-3：百分比是一级遥测信息）
          Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(value: ratio, minHeight: 4),
              ),
              const SizedBox(width: 8),
              Text(
                percent,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${formatBytes(item.bytesDone)}'
            '${item.bytesTotal == null ? '' : ' / ${formatBytes(item.bytesTotal!)}'}'
            '${item.status == tbl.DownloadStatus.running ? ' · ${formatSpeed(item.speedBps)} · ${formatEta(item.etaSec)}' : ''}'
            // 已用时间与速率/ETA 同行（PRD 3.3；按 createdAt 差值计算，
            // 随进度遥测回写（500ms 节流）驱动的列表重建即时刷新）
            '${item.status == tbl.DownloadStatus.running ? ' · ${AppStrings.labelElapsed} ${formatElapsed(DateTime.now().difference(item.createdAt))}' : ''}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          if (item.isFailed && item.errorCode != null) ...[
            const SizedBox(height: 2),
            Text(
              item.status == tbl.DownloadStatus.canceled
                  ? AppStrings.statusCanceled
                  : downloadErrorMessage(item.errorCode),
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
          ],
        ],
      ),
      isThreeLine: true,
      trailing: _trailingActions(context),
    );
  }

  Widget _historyRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: _thumb(item.thumbUrl),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${formatDateTime(item.createdAt)} · ${item.qualityLabel}'
        '${item.bytesTotal == null ? '' : ' · ${formatBytes(item.bytesTotal!)}'}'
        '${item.needsResave ? ' · ${AppStrings.albumNotSaved}' : ''}',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onOpenDetail,
    );
  }

  Widget _thumb(String? url) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 72,
        height: 44,
        child: url == null
            ? const Center(child: Icon(Icons.movie_outlined, size: 20))
            : Image.network(
                url,
                cacheWidth: 144,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const Center(child: Icon(Icons.broken_image_outlined, size: 20)),
              ),
      ),
    );
  }

  Widget? _trailingActions(BuildContext context) {
    final cmds = commands;
    if (cmds == null) return null;
    switch (item.status) {
      case tbl.DownloadStatus.running:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: AppStrings.actionPause,
              onPressed: () => cmds.pause(item.id),
              icon: const Icon(Icons.pause),
            ),
            IconButton(
              tooltip: AppStrings.actionCancel,
              onPressed: () => cmds.cancel(item.id),
              icon: const Icon(Icons.close),
            ),
          ],
        );
      case tbl.DownloadStatus.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: AppStrings.actionResume,
              onPressed: () => cmds.resume(item.id),
              icon: const Icon(Icons.play_arrow),
            ),
            IconButton(
              tooltip: AppStrings.actionCancel,
              onPressed: () => cmds.cancel(item.id),
              icon: const Icon(Icons.close),
            ),
          ],
        );
      case tbl.DownloadStatus.queued:
        return IconButton(
          tooltip: AppStrings.actionCancel,
          onPressed: () => cmds.cancel(item.id),
          icon: const Icon(Icons.close),
        );
      case tbl.DownloadStatus.failed:
      case tbl.DownloadStatus.canceled:
        return IconButton(
          tooltip: AppStrings.actionRetry,
          onPressed: () => cmds.retry(item.id),
          icon: const Icon(Icons.refresh),
        );
      default:
        return null;
    }
  }
}

extension on TaskItem {
  /// 状态中文标签（行内副标识）
  String get statusLabel => switch (status) {
        tbl.DownloadStatus.queued => AppStrings.dlSectionQueued,
        tbl.DownloadStatus.running => AppStrings.dlSectionActive,
        tbl.DownloadStatus.paused => AppStrings.actionPause,
        tbl.DownloadStatus.completed => AppStrings.dlSectionHistory,
        tbl.DownloadStatus.failed => AppStrings.dlSectionFailed,
        tbl.DownloadStatus.canceled => AppStrings.statusCanceled,
      };
}
