/// 端点配置外置（DESIGN §6.7，方案 A → A' 的核心增强）。
///
/// 加载顺序（§6.7）：
/// 1. 内置 assets（assets/config/endpoints.json，经注入的 assetLoader 读取，
///    保持本文件零 platform import）；
/// 2. shared_preferences 缓存的远端版本（版本号更高则原子替换）；
/// 3. 启动后台异步尝试远端拉取（remoteUrl 可配，默认空 = 关闭，绝不影响离线可用）；
/// 4. EndpointDrift（E07）触发时主动刷新一次（[onEndpointDrift]）。
///
/// dio 经构造注入以便测试 mock（DESIGN §9-2）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// prefs 键（DESIGN §5.4）。
const String kEndpointConfigJsonPrefKey = 'endpoint.configJson';
const String kEndpointConfigVersionPrefKey = 'endpoint.configVersion';

/// 内置端点配置的 assets 路径。
const String kBundledEndpointsAssetPath = 'assets/config/endpoints.json';

/// assets 加载器抽象：生产侧由组合根注入 `rootBundle.loadString` 包装，
/// 测试注入内存实现（保持解析层零 platform import，DESIGN §9-8）。
typedef AssetLoader = Future<String?> Function(String path);

/// 主源端点（syndication）。
class PrimaryEndpoint {
  const PrimaryEndpoint({
    required this.kind,
    required this.urlTemplate,
    required this.tokenAlgo,
    required this.ua,
    required this.timeoutMs,
  });

  factory PrimaryEndpoint.fromJson(Map<String, dynamic> json) => PrimaryEndpoint(
        kind: json['kind'] as String? ?? 'syndication',
        urlTemplate: json['urlTemplate'] as String? ?? '',
        tokenAlgo: json['tokenAlgo'] as String? ?? 'radix36-v1',
        ua: json['ua'] as String? ?? kDefaultBrowserUa,
        timeoutMs: (json['timeoutMs'] as num?)?.toInt() ?? 6000,
      );

  /// 端点类别，当前恒为 'syndication'。
  final String kind;

  /// 含 {id} {token} {lang} 占位符的 URL 模板。
  final String urlTemplate;

  /// token 算法版本标识（'radix36-v1'，见 DESIGN §6.2）。
  final String tokenAlgo;

  /// 普通浏览器 UA（§6.1；明确不采用 Googlebot 伪装）。
  final String ua;

  /// 接收超时毫秒（§6.1：6s）。
  final int timeoutMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind,
        'urlTemplate': urlTemplate,
        'tokenAlgo': tokenAlgo,
        'ua': ua,
        'timeoutMs': timeoutMs,
      };
}

/// 备源端点（fxtwitter，默认关闭，仅 RateLimited/EndpointDrift 时降级备援）。
class FallbackEndpoint {
  const FallbackEndpoint({
    required this.kind,
    required this.enabled,
    required this.urlTemplate,
  });

  factory FallbackEndpoint.fromJson(Map<String, dynamic> json) => FallbackEndpoint(
        kind: json['kind'] as String? ?? 'fxtwitter',
        // 防御性默认关闭（§12-13：结构未对账锁定前不启用）。
        enabled: json['enabled'] == true,
        urlTemplate:
            json['urlTemplate'] as String? ?? 'https://api.fxtwitter.com/status/{id}',
      );

  final String kind;
  final bool enabled;

  /// 含 {id} 占位符的 URL 模板（官方 /status/:id 路径，§6.4）。
  final String urlTemplate;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind,
        'enabled': enabled,
        'urlTemplate': urlTemplate,
      };
}

/// EndpointDrift 守卫参数（E07 判定依据）。
class DriftGuard {
  const DriftGuard({
    required this.typenameEquals,
    required this.requiredFields,
  });

  factory DriftGuard.fromJson(Map<String, dynamic> json) {
    final raw = json['requiredFields'];
    return DriftGuard(
      typenameEquals: json['typenameEquals'] as String? ?? 'Tweet',
      // 字段缺失时回落 §6.7 默认守卫（远端配置不得静默关闭 E07 守卫）。
      // 默认守卫不含 mediaDetails：纯文本推文该字段整体缺失是合法形态，
      // 守卫只做响应整体形状检查（error_codes.md 实现注记，缺失走 E05）。
      requiredFields: raw is List
          ? raw.whereType<String>().toList()
          : const <String>['user.screen_name'],
    );
  }

  /// __typename 必须等于该值，否则判定漂移。
  final String typenameEquals;

  /// 关键字段路径列表（点号分隔，如 'user.screen_name'），缺失即漂移。
  final List<String> requiredFields;

  Map<String, Object?> toJson() => <String, Object?>{
        'typenameEquals': typenameEquals,
        'requiredFields': requiredFields,
      };
}

/// 与 DESIGN §6.1 一致的普通浏览器 UA 兜底值（远端配置缺 ua 字段时使用）。
const String kDefaultBrowserUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';

/// 远端热更 timeoutMs 合法域下界：dio 语义为 receiveTimeout > 0 才启用超时，
/// 低于该值等于禁用超时（请求可无限挂起，E02 兜底与 §6.1 的 6s 预算失效），
/// 整套配置按无效拒绝、保留现有配置走回落。
const int kMinEndpointTimeoutMs = 500;

/// 远端热更 timeoutMs 合法域上界：防远端配置把解析请求拖成超长阻塞。
const int kMaxEndpointTimeoutMs = 30000;

/// 端点配置整体（assets/config/endpoints.json 的 Dart 侧，§6.7 schema）。
class EndpointConfig {
  const EndpointConfig({
    required this.version,
    required this.primary,
    required this.fallback,
    required this.driftGuard,
  });

  /// 内置预设 v1（与 assets/config/endpoints.json 初始内容一致；
  /// assets 不可用时的最终兜底，保证离线可用）。
  factory EndpointConfig.builtIn() => EndpointConfig.fromMap(const <String, Object?>{
        'version': 1,
        'primary': <String, Object?>{
          'kind': 'syndication',
          'urlTemplate':
              'https://cdn.syndication.twimg.com/tweet-result?id={id}&lang={lang}&token={token}',
          'tokenAlgo': 'radix36-v1',
          'ua': kDefaultBrowserUa,
          'timeoutMs': 6000,
        },
        'fallback': <String, Object?>{
          'kind': 'fxtwitter',
          'enabled': false,
          'urlTemplate': 'https://api.fxtwitter.com/status/{id}',
        },
        'driftGuard': <String, Object?>{
          'typenameEquals': 'Tweet',
          // 不含 mediaDetails：纯文本推文该字段整体缺失是合法形态（走 E05），
          // 守卫只做响应整体形状检查（error_codes.md 实现注记）。
          'requiredFields': ['user.screen_name'],
        },
      });

  /// 宽容解析：结构不完整或字段类型突变（如 version 为字符串）时返回 null
  /// （调用方回落现有配置，不抛异常）——TypeError 与 FormatException 同为
  /// 「配置无效」，绝不逃逸（load() 的后台远端拉取是 unawaited 的）。
  static EndpointConfig? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return EndpointConfig.fromMap(decoded);
    } on Object {
      return null; // 非法 JSON / 字段类型突变：按配置无效处理。
    }
  }

  factory EndpointConfig.fromMap(Map<String, dynamic> json) {
    final primaryRaw = json['primary'];
    final fallbackRaw = json['fallback'];
    final guardRaw = json['driftGuard'];
    return EndpointConfig(
      version: (json['version'] as num?)?.toInt() ?? 0,
      primary: primaryRaw is Map<String, dynamic>
          ? PrimaryEndpoint.fromJson(primaryRaw)
          : PrimaryEndpoint.fromJson(const <String, dynamic>{}),
      fallback: fallbackRaw is Map<String, dynamic>
          ? FallbackEndpoint.fromJson(fallbackRaw)
          : FallbackEndpoint.fromJson(const <String, dynamic>{}),
      driftGuard: guardRaw is Map<String, dynamic>
          ? DriftGuard.fromJson(guardRaw)
          : DriftGuard.fromJson(const <String, dynamic>{}),
    );
  }

  final int version;
  final PrimaryEndpoint primary;
  final FallbackEndpoint fallback;
  final DriftGuard driftGuard;

  /// 配置是否可用于发起请求（三重门禁，任一不过则整套配置无效走回落）：
  /// - 主源模板必须含 {id} 占位符；
  /// - 版本号 > 0；
  /// - timeoutMs 在合法域 [kMinEndpointTimeoutMs, kMaxEndpointTimeoutMs] 内
  ///   （下界防 dio 超时被禁用后请求无限挂起且无回滚通道，上界防超长阻塞）。
  bool get isUsable =>
      primary.urlTemplate.contains('{id}') &&
      version > 0 &&
      primary.timeoutMs >= kMinEndpointTimeoutMs &&
      primary.timeoutMs <= kMaxEndpointTimeoutMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'primary': primary.toJson(),
        'fallback': fallback.toJson(),
        'driftGuard': driftGuard.toJson(),
      };
}

/// 端点配置仓库：内置加载 + prefs 缓存 + 远端版本原子替换 + drift 触发刷新。
class EndpointConfigRepository {
  EndpointConfigRepository({
    required this._dio,
    required this._prefs,
    required this._assetLoader,
    String? remoteUrl,
  }) : _remoteUrl = (remoteUrl == null || remoteUrl.trim().isEmpty) ? null : remoteUrl;

  final Dio _dio;
  final SharedPreferences _prefs;
  final AssetLoader _assetLoader;
  final String? _remoteUrl;

  EndpointConfig? _current;
  bool _refreshInFlight = false;

  /// 当前生效配置；未加载过时返回内置兜底。
  EndpointConfig get current => _current ?? EndpointConfig.builtIn();

  /// 是否已加载（区分「内置兜底」与「真实加载」）。
  bool get isLoaded => _current != null;

  /// 加载顺序：内置 assets → prefs 缓存（版本更高则原子替换）→ 后台远端拉取。
  /// 任何一步失败都回落到上一步，绝不抛异常（离线可用优先）。
  Future<EndpointConfig> load() async {
    final bundled = await _loadBundled();
    var chosen = bundled;
    final cached = _loadCached();
    if (cached != null && cached.version > chosen.version) {
      chosen = cached; // 原子替换：整体对象替换，无中间态
    }
    _current = chosen;
    // 启动后台异步尝试远端拉取（默认空 = 关闭，绝不影响本次返回）。
    if (_remoteUrl != null) {
      unawaited(refreshFromRemote());
    }
    return chosen;
  }

  /// 从远端拉取新配置：仅在版本严格更高且结构合法时原子替换并持久化。
  /// 返回是否发生了替换。失败（网络/解析/版本不高）一律回落保持现状。
  Future<bool> refreshFromRemote() async {
    final url = _remoteUrl;
    if (url == null || _refreshInFlight) return false;
    _refreshInFlight = true;
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
          headers: const <String, String>{'Accept': 'application/json'},
        ),
      );
      if (response.statusCode != 200) return false;
      final next = EndpointConfig.tryParse(response.data);
      if (next == null || !next.isUsable) return false;
      if (next.version <= current.version) return false;
      // 原子替换持久化：先写配置体，版本号最后写入作为提交点——
      // 中途崩溃时旧版本号不会被新配置选中，避免半提交状态。
      await _prefs.setString(kEndpointConfigJsonPrefKey, jsonEncode(next.toJson()));
      await _prefs.setInt(kEndpointConfigVersionPrefKey, next.version);
      _current = next;
      return true;
    } on Object {
      // 任何异常（网络失败 / 畸形远端响应 / 持久化失败）一律回落保持现状
      // （§11.1 测试覆盖），绝不逃逸——load() 里本方法是 unawaited 的，
      // 逃逸即启动期未处理异步异常。
      return false;
    } finally {
      _refreshInFlight = false;
    }
  }

  /// EndpointDrift（E07）触发时主动刷新一次（§6.7）：
  /// X 小改参数（UA/超时/字段名/token 算法版本）可免发版自愈。
  /// 编排层捕获 EndpointDrift 后调用本方法，随后用新配置重试解析。
  Future<bool> onEndpointDrift() => refreshFromRemote();

  Future<EndpointConfig> _loadBundled() async {
    try {
      final raw = await _assetLoader(kBundledEndpointsAssetPath);
      final parsed = EndpointConfig.tryParse(raw);
      if (parsed != null && parsed.isUsable) return parsed;
    } on Object {
      // assets 缺失/损坏（loader 抛异常）→ 内置兜底，离线可用优先。
      return EndpointConfig.builtIn();
    }
    return EndpointConfig.builtIn();
  }

  EndpointConfig? _loadCached() {
    final raw = _prefs.getString(kEndpointConfigJsonPrefKey);
    final parsed = EndpointConfig.tryParse(raw);
    if (parsed == null || !parsed.isUsable) return null;
    return parsed;
  }
}
