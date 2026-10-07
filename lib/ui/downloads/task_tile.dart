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
import 'package:clipvault/core/local_thumbnail.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/data/database.dart';
import 'package:clipvault/data/history_repository.dart';
import 'package:clipvault/data/tables.dart' as tbl;
import 'package:clipvault/download/download_engine.dart';
import 'package:clipvault/download/download_task.dart' as dt;
import 'package:clipvault/download/gallery_saver.dart';
import 'package:clipvault/ui/common/retry_image.dart';
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/parse/parser_provider.dart'
    show refreshVariantUrl, tweetParserProvider;
import 'package:clipvault/settings/proxy_auto_provider.dart';
import 'package:clipvault/settings/settings_controller.dart';
import 'package:clipvault/ui/common/error_views.dart';
import 'package:clipvault/ui/common/preview_card.dart' show PreviewCard;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipvault/ui/common/navigator_key.dart';

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
    this.activeMs = 0,
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

  /// 累计活跃毫秒（净时长口径的已用时间，仅 running 态累计）。
  final int activeMs;
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

  /// 终态且可从列表直接删记录（completed/canceled/failed）；
  /// 进行中/排队/暂停行先走取消流程，不提供直接删行。
  bool get isDeletable => isHistory || isFailed;

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

  /// 从 tweetJson 快照提取缩略图 URL（删记录时清理本地缩略图用；
  /// 与 [thumbUrl] 同解析口径的静态版，不构造 TaskItem）。
  static String? thumbnailUrlOf(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final v = decoded['thumbnailUrl'];
        return v is String && v.isNotEmpty ? v : null;
      }
    } catch (_) {
      // 快照损坏：无缩略图可清理
    }
    return null;
  }

  /// tweetJson 快照中的视频时长（毫秒；缺失/损坏时 null，历史行封面徽标用）。
  int? get durationMillis => (_meta?['durationMillis'] as num?)?.toInt();

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

  /// 删除终态记录行（用户反馈 2026-09-30）：缺省仅删记录、视频文件保留；
  /// .part 断点残片随行清理。已取消/失败/已完成记录均可删。
  Future<void> deleteRecord(int id);
}

/// 启动恢复分流入口（P0-2）：经命令层把未完成记录按
/// 「仅 Wi-Fi 偏好 + 当前连接」分流为交引擎续传 / 挂起等待 Wi-Fi，
/// 修复重启后绕过偏好直接走蜂窝的缺陷。
/// 生产实现见 [EngineDownloadCommands.restoreRecords]；假实现无此方法，
/// 直接跳过（测试环境不执行启动恢复）。
Future<void> restoreDownloadRecords(
  DownloadCommands commands,
  Iterable<DownloadRecord> rows,
) async {
  if (commands is EngineDownloadCommands) {
    await commands.restoreRecords(rows);
  }
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

/// 当前是否处于 Wi-Fi 的观察口（初值 + 变化流）。
///
/// 平台插件不可用（widget 测试/桌面）时按「已连接」处理并吞掉后续事件，
/// 避免把挂起判定建立在一个永远报错的流上。
final StreamProvider<bool> onWifiProvider = StreamProvider<bool>((ref) async* {
  final checker = ref.watch(connectivityCheckerProvider);
  bool current;
  try {
    current = await checker.isOnWifi;
  } catch (_) {
    current = true;
  }
  yield current;
  yield* checker.onWifiChanged.handleError((_) {});
});

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
    Future<void> Function()? proxyPreflight,
  })  : _wifiOnlyEnabled = wifiOnlyEnabled ?? _wifiOffByDefault,
        _connectivity = connectivity ?? const _NoopConnectivityChecker(),
        _proxyPreflight = proxyPreflight {
    // Wi-Fi 恢复 → 先代理预检再补交挂起任务（订阅随 dispose 取消）：
    // 蜂窝开代理回 Wi-Fi 的场景，补交的下载直接走预检定好的路径。
    _wifiSub = _connectivity.onWifiChanged.listen((onWifi) {
      if (onWifi) unawaited(_preflightThenFlush());
    });
  }

  static bool _wifiOffByDefault() => false;

  final DownloadEngine _engine;
  final HistoryRepository _repo;
  final bool Function() _wifiOnlyEnabled;
  final ConnectivityChecker _connectivity;

  /// 代理预检注入（§6.9 自动调节，生产接协调器 preflight；测试注入
  /// recorder 断言挂点）。null = 无预检（行为等同改动前）。
  final Future<void> Function()? _proxyPreflight;

  /// 因仅 Wi-Fi 偏好挂起、尚未交引擎的行主键集合。
  final Set<int> _heldBack = <int>{};
  StreamSubscription<bool>? _wifiSub;
  bool _flushing = false;

  /// 行主键 → 引擎任务 id
  static String engineIdOf(int rowId) => 'rec_$rowId';

  /// 预检 + 补交挂起任务（Wi-Fi 恢复路径）：预检等待由协调器内预算封顶
  ///（默认 3s，TTL 缓存后近零成本），后续补交即走正确代理路径。
  Future<void> _preflightThenFlush() async {
    await _proxyPreflight?.call();
    await _flushHeld();
  }

  @override
  Future<DownloadEnqueueResult> enqueue({
    required String tweetId,
    required VideoVariant variant,
    required String tweetJson,
  }) async {
    // 自动代理预检（§6.9：Wi-Fi 直连可用→自动关 / 直连不可用→预探测
    // 启用）：放最前——随后补交的挂起任务与本次入队同批走正确路径。
    // await 但协调器内预算封顶（≤3s），TTL 缓存后近零成本。
    await _proxyPreflight?.call();
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

  /// 删除下载记录（用户反馈 2026-09-30）：仅删记录行，视频文件
  /// （filePath）保留；.part 断点残片随行清理（非成品视频，行删后即成
  /// 缓存统计不可见的孤儿）。引擎内存若仍驻留同 id 任务先移除。
  @override
  Future<void> deleteRecord(int id) async {
    if (_heldBack.remove(id)) {
      // 挂起任务引擎不知情，直接删行
    } else if (_engine.task(engineIdOf(id)) != null) {
      _engine.cancel(engineIdOf(id));
    }
    final row = await _repo.deleteById(id);
    if (row != null) {
      // 本地缩略图随行清理（可再拉取，与 .part 的活动任务守卫不同，
      // 无需引用检查——同推文兄弟行命中缺失时懒拉一次即自愈）
      await ThumbnailStore.purgeFor(
          row.tweetId, TaskItem.thumbnailUrlOf(row.tweetJson));
    }
    final part = row?.partPath;
    if (part == null || part.isEmpty) return;
    // .part 由业务键确定性派生（'{tweetId}_{bitrate}.part'），同键重下的
    // 活动任务与新删旧行共用同一物理残片——有未终结任务引用时跳过清理，
    // 否则会 unlink 运行中任务的断点文件致其从零重下（审查发现，工作流
    // wf_d5643288 对抗验证确认）。
    final partInUse = _engine.tasks.any((t) =>
        !t.isSettled && t.partPath != null && t.partPath == part);
    if (partInUse) return;
    try {
      final file = File(part);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 残片清理失败（占用/权限）忽略，不阻断记录删除
    }
  }

  /// 启动恢复分流（P0-2，经 [restoreDownloadRecords] 调用）：仅 Wi-Fi 偏好开启且当前非 Wi-Fi 时，
  /// 未完成行挂入 [_heldBack]（与运行时挂起同一语义，Wi-Fi 恢复补交），
  /// 其余交引擎断点续传。修复此前「恢复路径不读偏好，重启即在蜂窝
  /// 网络直接开跑」的缺陷。
  ///
  /// 终态行（failed/canceled，2026-10-04 修复）不做 Wi-Fi 门控，始终
  /// 登记进引擎：restoreFrom 对终态仅登记不调度（不会自动跑流量），
  /// 但它是「一键重试」的内存句柄——挂起会导致蜂窝网络下重试静默空操作。
  Future<void> restoreRecords(Iterable<DownloadRecord> rows) async {
    final engineBound = <dt.DownloadTask>[];
    for (final row in rows) {
      final status = engineStatusOf(row.status);
      final settled = status == dt.DownloadStatus.failed ||
          status == dt.DownloadStatus.canceled;
      if (!settled && _wifiOnlyEnabled() && !await _connectivity.isOnWifi) {
        _heldBack.add(row.id);
        continue;
      }
      engineBound.add(_restoreTaskFromRow(row));
    }
    if (engineBound.isNotEmpty) {
      await _engine.restoreFrom(engineBound);
    }
  }

  /// 恢复行 → 引擎任务：携带断点续传所需字段
  /// （bytesDone/bytesTotal/filePath/partPath，引擎按 .part 实长对齐）
  /// 与净时长累计值（activeMs，跨重启延续）。
  dt.DownloadTask _restoreTaskFromRow(DownloadRecord row) {
    return _taskFromRow(row).copyWith(
      status: engineStatusOf(row.status),
      bytesDone: row.bytesDone,
      bytesTotal: row.bytesTotal,
      activeMs: row.activeMs,
      filePath: row.filePath,
      partPath: row.partPath,
    );
  }

  /// 记录状态串 → 引擎侧枚举（两侧枚举同名；未知回落 queued）。
  static dt.DownloadStatus engineStatusOf(String name) {
    for (final s in dt.DownloadStatus.values) {
      if (s.name == name) return s;
    }
    return dt.DownloadStatus.queued;
  }

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
            activeMs: Value(task.activeMs),
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
    // 403/410 直链过期重解析（§4.3；2026-10-04 接线修复：此前生产从未
    // 注入 UrlRefresher，旧任务直链过期后一键重试立即 urlExpired 失败，
    // 表现为「重试进入下载中但很快失败」）。惰性经 ref.read 取解析器：
    // 引擎只在刷新时机才需要解析器，避免构造期依赖 FutureProvider。
    urlRefresher: (tweetId, bitrate) async {
      try {
        final parser = await ref.read(tweetParserProvider.future);
        return await refreshVariantUrl(parser, tweetId, bitrate);
      } catch (_) {
        return null; // 端点仓库加载失败等：按 urlExpired 收敛，重试再试
      }
    },
    // 直连失败兜底（§6.9 自动代理调节）：引擎网络类异常且当前 DIRECT 时
    // 触发探测；协调器内部单飞+冷却去重。unawaited——退避节奏不受探测
    // 耗时影响，探测完成后 findProxy 回调实时读缓存即切换。
    onDirectFailure: () => unawaited(
        ref.read(proxyAutoCoordinatorProvider).onDirectFailure(source: 'download')),
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

/// 相册保存装配（P1-8）：gal 生产实现外包一层权限预解释——
/// 首次触发系统权限弹窗前先弹应用内说明（拒绝后的降级路径提前告知），
/// 避免用户在下载完成的瞬间面对无上下文的系统弹窗习惯性拒绝。
const String _kAlbumExplainedPref = 'album.explained';

final Provider<GallerySaver> gallerySaverProvider =
    Provider<GallerySaver>((_) {
  return PreExplainGallerySaver(
    inner: const GalGallerySaver(),
    contextResolver: () => navigatorKey.currentContext,
    hasExplained: () async =>
        (await SharedPreferences.getInstance()).getBool(_kAlbumExplainedPref) ??
        false,
    markExplained: () async => (await SharedPreferences.getInstance())
        .setBool(_kAlbumExplainedPref, true),
    explainTitle: AppStrings.albumExplainTitle,
    explainBody: AppStrings.albumExplainBody,
    explainConfirm: AppStrings.albumExplainConfirm,
  );
});

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
    // 代理预检（§6.9 自动调节）：enqueue 顶部与 Wi-Fi 恢复补交前调用
    proxyPreflight: () =>
        ref.read(proxyAutoCoordinatorProvider).preflight(),
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

/// 主壳 Tab 索引（0 首页 / 1 下载 / 2 我的）。
/// 放在装配文件供跨页导航（如下载 Tab 空态「去解析第一个视频」切回首页）。
/// Riverpod 3 无 StateProvider，用轻量 Notifier 承载。
class HomeTabController extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

final NotifierProvider<HomeTabController, int> homeTabProvider =
    NotifierProvider<HomeTabController, int>(HomeTabController.new);

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
      activeMs: r.activeMs,
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

/// 单任务行：进度 / 速率 / ETA / 操作（§7.1-3）。
///
/// 2026-10-04 信息收敛：
/// - 封面统一 80×45（16:9）圆角 8：完成行叠时长徽标、失败行叠暗遮罩 +
///   红色告警（识别内容靠封面，不再是无差别的灰图标方块）；
/// - 失败行不再平铺多行错误长文案：行内只挂 4 字短胶囊（分辨率旁），
///   点击行弹「失败原因」BottomSheet 看全文并可重试；行尾重试收敛为
///   轻量圆形 tonal 按钮；
/// - 历史行行尾的 chevron 换 ⋮ 菜单（播放 / 分享 / 复制原链接 / 删除），
///   明确点按后的去向语义。
class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.item,
    this.onOpenDetail,
    this.onDeleteRecord,
    this.onPlay,
    this.onShare,
    this.onCopyLink,
    this.commands,
    this.waitingWifi = false,
    this.cooldownActive = false,
  });

  final TaskItem item;

  /// 历史条目点击进入详情（HistoryScreen）
  final VoidCallback? onOpenDetail;

  /// 终态条目长按删除记录入口（缺省仅删记录，视频保留）
  final VoidCallback? onDeleteRecord;

  /// 历史菜单「播放」（本地文件已清理时由调用方置 null → 菜单项禁用）
  final VoidCallback? onPlay;

  /// 历史菜单「分享」（share_plus 系统分享面板；文件缺失时置 null）
  final VoidCallback? onShare;

  /// 历史菜单「复制原链接」（推文 URL 写入剪贴板 + toast）
  final VoidCallback? onCopyLink;

  /// 命令回调来源（空则只读展示，测试/预览用）
  final DownloadCommands? commands;

  /// 仅 Wi-Fi 偏好挂起中（queued 行显示「等待 Wi-Fi 连接」而非「等待队列」）
  final bool waitingWifi;

  /// 429 全队列冷却进行中（paused 行显示「限速等待中」而非「暂停」）
  final bool cooldownActive;

  @override
  Widget build(BuildContext context) {
    if (item.isHistory) return _historyRow(context);
    return _activeRow(context);
  }

  /// 行内状态副标识：挂起/冷却场景用专属标签，其余按状态映射。
  String get _statusLabel {
    if (waitingWifi && item.status == tbl.DownloadStatus.queued) {
      return AppStrings.waitingWifiLabel;
    }
    if (cooldownActive && item.status == tbl.DownloadStatus.paused) {
      return AppStrings.cooldownPausedLabel;
    }
    return item.statusLabel;
  }

  /// 状态语义色（主题 B：四种状态此前长得一样，状态词埋在灰文本里）：
  /// running=primary / paused=primary 45%（勿用 tertiary——蓝紫色相被
  /// 主题 C 批评）/ queued=灰 / failed=error / canceled=灰（用户主动行为）。
  Color _statusColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (item.status) {
      case tbl.DownloadStatus.running:
        return scheme.primary;
      case tbl.DownloadStatus.paused:
        return scheme.primary.withValues(alpha: 0.45);
      case tbl.DownloadStatus.failed:
        return scheme.error;
      case tbl.DownloadStatus.queued:
      case tbl.DownloadStatus.completed:
      case tbl.DownloadStatus.canceled:
        return scheme.onSurfaceVariant;
    }
  }

  /// 进度条填充色：随状态语义（暂停态不再是与进行中无异的实心 primary）。
  Color _progressColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (item.status) {
      case tbl.DownloadStatus.failed:
        return scheme.error;
      case tbl.DownloadStatus.paused:
        return scheme.primary.withValues(alpha: 0.45);
      default:
        return scheme.primary;
    }
  }

  Widget _activeRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = item.progressRatio;
    final percent = ratio == null ? '--' : '${(ratio * 100).toInt()}%';
    final running = item.status == tbl.DownloadStatus.running;
    final failed = item.status == tbl.DownloadStatus.failed;
    final statusColor = _statusColor(context);
    // 失败行短标签：完整话术不平铺在行内，点击行弹详情（2026-10-04）
    final failedTag = failed ? downloadErrorTag(item.errorCode) : null;
    return ListTile(
      leading: _thumb(context),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      // 失败行点按 → 失败原因 BottomSheet（全文 + 重试入口）
      onTap: failed ? () => _showErrorDetail(context) : null,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          // 质量 + 状态词拆分：状态词独立染色加粗（此前与清晰度同串同色）；
          // 失败行在状态词后追加 4 字短胶囊（替代多行红字错误文案）
          Row(
            children: [
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '${item.qualityLabel} · '),
                      TextSpan(
                        text: _statusLabel,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (failedTag != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    failedTag,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: scheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          // 进度条是「进行中」的可供性——终态行（已取消/失败）不渲染停滞
          // 半截进度条与百分比（与终态语义直接矛盾，用户反馈 2026-09-30
          // 「很难理解」）；进度降级为遥测行内的数据百分比。
          // 活动态保留：百分比与进度条同行独立展示（§7.1-3）；
          // 进度条 8dp + 圆角 + 状态语义色；合成语义描述供读屏一次听懂。
          if (!item.isFailed)
            Semantics(
            label: ratio == null
                ? null
                : '已下载百分之${(ratio * 100).toInt()}'
                    '${item.speedBps > 0 ? '，速率${formatSpeed(item.speedBps)}' : ''}'
                    '${item.etaSec != null && item.etaSec! > 0 ? '，约剩余${item.etaSec}秒' : ''}',
            child: Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                    color: _progressColor(context),
                    // 深色轨道需 ≥0.24 不透明度才达 3:1（核验修正值）
                    backgroundColor:
                        Theme.of(context).brightness == Brightness.dark
                            ? scheme.onSurface.withValues(alpha: 0.24)
                            : scheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  percent,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: running ? scheme.primary : scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // 遥测分级（主题 B：此前五类信息 12px 单灰平铺，无主次）：
          // 字节/已用=次要灰；速率=13px onSurface；ETA=primary w600 强调。
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${formatBytes(item.bytesDone)}'
                      '${item.bytesTotal == null ? '' : ' / ${formatBytes(item.bytesTotal!)}'}',
                ),
                // 终态行进度条已不渲染（见上）——百分比并入遥测行作
                // 纯数据陈述（「24.5 MB / 66.2 MB · 37%」）
                if (item.isFailed && ratio != null)
                  TextSpan(text: ' · ${(ratio * 100).toInt()}%'),
                if (running) ...[
                  const TextSpan(text: ' · '),
                  TextSpan(
                    text: formatSpeed(item.speedBps),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (item.etaSec != null && item.etaSec! > 0) ...[
                    const TextSpan(text: ' · '),
                    TextSpan(
                      text: formatEta(item.etaSec),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                  // 已用时间 = 累计活跃毫秒（P2-4：排队/暂停/冷却等待不计入）
                  const TextSpan(text: ' · '),
                  TextSpan(
                    text: '${AppStrings.labelElapsed} '
                        '${formatElapsed(Duration(milliseconds: item.activeMs))}',
                  ),
                ],
              ],
            ),
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          // 失败原因长文案已收敛进行点按的 BottomSheet（2026-10-04），
          // 行内只保留上方 4 字短胶囊。
        ],
      ),
      // 行高随内容：活动态三行（状态/进度/遥测）；终态两行（状态/遥测）
      isThreeLine: item.isActive || item.isQueued,
      // 终态行（失败/已取消）长按删记录；进行中/排队行不接（先走取消）
      onLongPress: item.isDeletable ? onDeleteRecord : null,
      trailing: _trailingActions(context),
    );
  }

  Widget _historyRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: _thumb(context),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${formatDateTime(item.createdAt)} · ${item.qualityLabel}'
        '${item.bytesTotal == null ? '' : ' · ${formatBytes(item.bytesTotal!)}'}'
        '${item.needsResave ? ' · ${AppStrings.albumNotSaved}' : ''}'
        '${item.filePath == null ? ' · ${AppStrings.fileCleaned}' : ''}',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      // 无语义的 chevron 换 ⋮ 菜单（2026-10-04）：明确点按后的去向
      // （播放/分享/复制原链接/删除）；整行点按仍进详情。
      trailing: _historyMenu(context),
      onTap: onOpenDetail,
      // 长按 = 仅删记录（视频保留）；点击进详情可彻底删除（记录+文件）
      onLongPress: onDeleteRecord,
    );
  }

  /// 历史行 ⋮ 菜单：播放 / 分享 / 复制原链接 / 删除。
  /// 文件缺失（已清理）时播放与分享置灰；删除走 onDeleteRecord 确认链路。
  Widget _historyMenu(BuildContext context) {
    Widget menuRow(IconData icon, String label, {Color? color}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: color == null ? null : TextStyle(color: color),
              ),
            ),
          ],
        );
    return PopupMenuButton<String>(
      tooltip: AppStrings.actionMore,
      icon: const Icon(Icons.more_vert),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (value) {
        switch (value) {
          case 'play':
            onPlay?.call();
          case 'share':
            onShare?.call();
          case 'copy':
            onCopyLink?.call();
          case 'delete':
            onDeleteRecord?.call();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'play',
          enabled: onPlay != null,
          child: menuRow(Icons.play_arrow, AppStrings.actionPlay),
        ),
        PopupMenuItem(
          value: 'share',
          enabled: onShare != null,
          child: menuRow(Icons.share_outlined, AppStrings.actionShare),
        ),
        PopupMenuItem(
          value: 'copy',
          enabled: onCopyLink != null,
          child: menuRow(Icons.copy, AppStrings.actionCopyLink),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: menuRow(
            Icons.delete_outline,
            AppStrings.actionDelete,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      ],
    );
  }

  /// 失败行点按 → 失败原因详情（BottomSheet）：完整错误话术 + 重试入口，
  /// 替代此前平铺在行内的多行红字（与右侧重试按钮割裂的排版）。
  void _showErrorDetail(BuildContext context) {
    final cmds = commands;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.dlErrorDetailTitle,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              Text(
                downloadErrorMessage(item.errorCode),
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                ),
              ),
              if (cmds != null) ...[
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      cmds.retry(item.id);
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text(AppStrings.actionRetry),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 封面缩略图：80×45（16:9 标准比例）圆角 8。
  /// - 完成/取消行：右下角叠视频时长徽标（识别内容的关键依据）；
  /// - 失败行：暗遮罩 + 中央红色告警徽标（状态一眼可辨）；
  /// - 无快照/加载失败：灰底 + 图标兜底（快照缺失多为历史遗留行）。
  Widget _thumb(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = item.thumbUrl;
    final duration = item.durationMillis;
    final failed = item.status == tbl.DownloadStatus.failed;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 80,
        height: 45,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url == null)
              ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: const Center(child: Icon(Icons.movie_outlined, size: 20)),
              )
            else
              RetryImage(
                image: localThumbnail(item.tweetId, url, cacheWidth: 160),
                fit: BoxFit.cover,
                errorBuilder: (_) => ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: const Center(
                      child: Icon(Icons.broken_image_outlined, size: 20)),
                ),
              ),
            if (failed)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.45),
                child: Center(
                  child: Icon(Icons.error_outline, size: 20, color: scheme.error),
                ),
              )
            else if (item.isHistory && duration != null && duration > 0)
              Align(
                alignment: Alignment.bottomRight,
                child: Container(
                  margin: const EdgeInsets.all(4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    PreviewCard.formatDuration(duration),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
          ],
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
              visualDensity: VisualDensity.compact,
              tooltip: AppStrings.actionPause,
              onPressed: () => cmds.pause(item.id),
              icon: const Icon(Icons.pause),
            ),
            const SizedBox(width: 4),
            _cancelButton(context, cmds),
          ],
        );
      case tbl.DownloadStatus.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: AppStrings.actionResume,
              // 冷却中被系统暂停的任务点「继续」纹丝不动（_pump 被冷却挡住）：
              // 给即时反馈说明将自动恢复，避免看起来像功能失效。
              onPressed: () {
                if (cooldownActive) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text(AppStrings.resumeInCooldown)),
                  );
                }
                cmds.resume(item.id);
              },
              icon: const Icon(Icons.play_arrow),
            ),
            const SizedBox(width: 4),
            _cancelButton(context, cmds),
          ],
        );
      case tbl.DownloadStatus.queued:
        return _cancelButton(context, cmds);
      case tbl.DownloadStatus.failed:
        // 失败行重试收敛为轻量圆形 tonal 按钮（2026-10-04）：错误全文与
        // 重试已在行点按的失败原因 Sheet 内，行尾文字按钮与左侧胶囊
        // 挤在一行的割裂排版一并消除。
        return IconButton.filledTonal(
          visualDensity: VisualDensity.compact,
          tooltip: AppStrings.actionRetry,
          onPressed: () => cmds.retry(item.id),
          icon: const Icon(Icons.refresh, size: 20),
        );
      case tbl.DownloadStatus.canceled:
        // 取消后的续传语义是「重新下载」而非「重试」（取消是用户主动
        // 行为，2026-09-30）；另挂独立删除按钮：仅删记录的轻量操作免确认
        // 弹窗（judge 裁决 2026-09-30），视频文件保留；彻底删除仍走长按
        // 确认路径（onDeleteRecord）与历史详情页，两档语义不混淆。
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: AppStrings.actionRedownload,
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 36),
                  textStyle: const TextStyle(fontSize: 13),
                ),
                onPressed: () => cmds.retry(item.id),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text(AppStrings.actionRedownload),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: AppStrings.actionDelete,
              color: Theme.of(context).colorScheme.error,
              onPressed: () => cmds.deleteRecord(item.id),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        );
      default:
        return null;
    }
  }

  /// 取消按钮（主题 D：破坏性暗示——error 前景色 + 4dp 间距防误触；
  /// 取消保留 .part，Snackbar 撤销=断点重试无损失）。
  Widget _cancelButton(BuildContext context, DownloadCommands cmds) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: AppStrings.actionCancel,
      color: Theme.of(context).colorScheme.error,
      onPressed: () {
        cmds.cancel(item.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(AppStrings.taskCanceled),
            action: SnackBarAction(
              label: AppStrings.actionUndo,
              onPressed: () => cmds.retry(item.id),
            ),
          ),
        );
      },
      icon: const Icon(Icons.close),
    );
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
