/// 自动代理调节协调器（DESIGN §6.9「双向自动调节」2026-10-07 增补）。
///
/// 解决手动代理开关的两极化痛点：
/// - 忘记开代理 → 解析/下载直连反复失败，只能手动去设置页开启；
/// - 回到直连可用的 Wi-Fi 忘记关 → 流量持续绕行代理。
///
/// 双向语义（纯逻辑，不依赖 Riverpod/Flutter，全部依赖构造注入）：
/// - **方向 A（自动启用，不限网络）**：直连失败 → 探测本地代理候选端口
///   （已保存地址优先，然后 127.0.0.1 × 常见端口）——两阶段验证：TCP 短
///   超时 + 经该代理发真实 HTTPS 请求（dart:io findProxy 仅支持 HTTP
///   CONNECT，SOCKS-only 端口在阶段 2 自然淘汰）→ 首个通过者自动启用
///   （经设置抽象走正常持久化写路径）+ 事件通知；
/// - **方向 B（自动禁用，仅 Wi-Fi）**：解析/下载前预检 [preflight]——
///   双主机（解析 CDN + 视频 CDN）强制直连探测都通才算直连可用（防
///   「只通一半」导致下载震荡），可用且手动代理开启 → 自动关闭。
///
/// 防抖四件套：
/// 1. 单飞：preflight 与探测各自共享 in-flight Future（并发触发只跑一遍）；
/// 2. 方向 A 全候选失败 → 60s 冷却（期间零探测）；
/// 3. 直连判定 TTL 缓存：成功 5min / 失败 30s（预检近零成本）；
/// 4. 自动切换后 2min 稳定期（双向生效，防边界网络来回震荡）；用户手动
///   改设置经 [markUserTouched] 立即解除。
///
/// 失败兜底接线（引擎/解析网络异常处）用 [onDirectFailure]：网络类失败
/// 且当前生效 DIRECT 时触发探测；探测在退避等待窗口内后台完成，下次
/// 重试经 findProxy 回调实时读缓存自动走新代理（无需重建 Dio）。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'app_http.dart' show SystemProxy, parseProxyAddress;
import 'net_diag.dart' show kDiagHost;

/// 时钟注入（测试用假时钟推进冷却/TTL/稳定期）。
typedef ProxyNowFn = DateTime Function();

/// 协调器所需的设置窄视图（缺省地址回落等计算留在 settings 层，
/// core 不反向依赖）。
class ProxyAutoSettingsView {
  const ProxyAutoSettingsView({
    required this.autoEnabled,
    required this.proxyEnabled,
    required this.effectiveProxyAddress,
  });

  /// 自动调节总开关（settings.proxyAuto）。
  final bool autoEnabled;

  /// 手动代理开关（settings.proxyEnabled；仅裁决 manual 注入）。
  final bool proxyEnabled;

  /// 手动代理生效地址（空地址已回落缺省后的值）。
  final String effectiveProxyAddress;
}

/// 设置读写抽象：生产由 settings/proxy_auto_provider.dart 适配
/// SettingsController（autoEnable/autoDisable 走正常持久化写路径，
/// 各自内部有串行门闩）；测试注入假实现。
abstract class ProxyAutoSettings {
  ProxyAutoSettingsView read();

  /// 自动启用：保存地址 + 打开开关（地址格式已由探测产出归一化）。
  Future<void> autoEnable(String address);

  /// 自动关闭：仅关开关（地址保留，重开免重填——与手动关闭同语义）。
  Future<void> autoDisable();
}

/// 自动切换通知（主壳订阅弹 SnackBar；source 标记触发来源便于排查）。
sealed class ProxyAutoEvent {
  const ProxyAutoEvent({required this.source});

  /// 'preflight' | 'download' | 'parse'
  final String source;
}

class ProxyAutoEnabledEvent extends ProxyAutoEvent {
  ProxyAutoEnabledEvent({required this.address, required super.source});

  /// 探测通过并已启用的代理地址（host:port）。
  final String address;
}

class ProxyAutoDisabledEvent extends ProxyAutoEvent {
  const ProxyAutoDisabledEvent({required super.source});
}

/// 直连判定缓存条目。
class _DirectCheckResult {
  _DirectCheckResult({required this.ok, required this.at});

  final bool ok;
  final DateTime at;
}

/// 自动代理调节协调器。
class ProxyAutoCoordinator {
  ProxyAutoCoordinator({
    required ProxyAutoSettings settings,
    required ProxyNowFn now,
    Future<bool> Function()? isOnWifi,
    String Function()? effectiveProxySetting,
    List<int> fallbackPorts = const [2080, 7890, 7897, 10808, 8118, 1080],
    List<String> directHosts = const [kDiagHost, 'video.twimg.com'],
    this.tcpProbeTimeout = const Duration(milliseconds: 800),
    this.connectProbeTimeout = const Duration(seconds: 5),
    this.directProbeTimeout = const Duration(seconds: 3),
    this.directOkTtl = const Duration(minutes: 5),
    this.directFailTtl = const Duration(seconds: 30),
    this.probeCooldown = const Duration(seconds: 60),
    this.minStablePeriod = const Duration(minutes: 2),
    this.preflightBudget = const Duration(seconds: 3),
    String connectProbeUrl = 'https://$kDiagHost/',
    String Function(String host) directProbeUrlOf = _defaultDirectProbeUrlOf,
    Future<bool> Function(String host, int port)? tcpProbe,
    Future<bool> Function(String host, int port)? proxyConnectProbe,
    Future<bool> Function(String host)? directHttpsProbe,
  })  : _settings = settings,
        _now = now,
        _isOnWifi = isOnWifi,
        _effectiveProxySetting =
            effectiveProxySetting ?? (() => SystemProxy.proxySetting),
        _fallbackPorts = fallbackPorts,
        _directHosts = directHosts,
        _connectProbeUrl = connectProbeUrl,
        _directProbeUrlOf = directProbeUrlOf,
        _tcpProbe = tcpProbe ??
            ((host, port) => _defaultTcpProbe(host, port, tcpProbeTimeout)),
        _proxyConnectProbe = proxyConnectProbe ??
            ((host, port) => _defaultProxyConnectProbe(
                host, port, connectProbeTimeout, connectProbeUrl)),
        _directHttpsProbe = directHttpsProbe ??
            ((host) => _defaultDirectHttpsProbe(
                host, directProbeTimeout, directProbeUrlOf));

  final ProxyAutoSettings _settings;
  final ProxyNowFn _now;
  final Future<bool> Function()? _isOnWifi;
  final String Function() _effectiveProxySetting;
  final List<int> _fallbackPorts;
  final List<String> _directHosts;
  final Future<bool> Function(String, int) _tcpProbe;
  final Future<bool> Function(String, int) _proxyConnectProbe;
  final Future<bool> Function(String) _directHttpsProbe;
  final String _connectProbeUrl;
  final String Function(String) _directProbeUrlOf;

  /// 候选 TCP 端口探测超时（本机回环无 DNS 开销，800ms 足够宽容）。
  final Duration tcpProbeTimeout;

  /// 经候选代理发真实 HTTPS 请求的总超时（CONNECT 隧道 + 响应头）。
  final Duration connectProbeTimeout;

  /// 强制直连单主机探测超时。
  final Duration directProbeTimeout;

  /// 直连判定缓存 TTL：成功（边界网络场景少探测）/ 失败（直连恢复的
  /// 发现要及时，但也不宜每次预检都等满超时）。
  final Duration directOkTtl;
  final Duration directFailTtl;

  /// 方向 A 全候选失败后的冷却（期间零探测，防失败风暴）。
  final Duration probeCooldown;

  /// 自动切换后的最短稳定期（双向生效，防来回震荡）。
  final Duration minStablePeriod;

  /// preflight 对调用方的等待预算：超时即返回，探测后台续跑落缓存。
  final Duration preflightBudget;

  static String _defaultDirectProbeUrlOf(String host) => 'https://$host/';

  Future<void>? _preflightFlight;
  Future<bool>? _probeFlight;
  DateTime? _probeCooldownUntil;
  DateTime? _lastAutoSwitchAt;
  _DirectCheckResult? _directCache;

  final StreamController<ProxyAutoEvent> _events =
      StreamController<ProxyAutoEvent>.broadcast();

  /// 自动切换通知流（主壳订阅弹 SnackBar）。
  Stream<ProxyAutoEvent> get events => _events.stream;

  /// 预检（解析/下载前调用，方向 B + 方向 A 预探测）。
  ///
  /// await 但等待不超过 [preflightBudget]：超时部分后台续跑、结果落 TTL
  /// 缓存不浪费；内部全 try/catch 绝不抛（网络增强能力不影响主流程）。
  Future<void> preflight() async {
    // 单飞清理必须走 whenComplete（监听器恒异步触发）：_runPreflight 存在
    // 无 await 的同步提前返回路径，try/finally 会在本处 ??= 赋值之前同步
    // 清空引用，留下永不失效的已完成 future，preflight 从此哑火。
    final work = _preflightFlight ??= _runPreflight().whenComplete(() {
      _preflightFlight = null;
    });
    try {
      await work.timeout(preflightBudget, onTimeout: () {});
    } catch (_) {
      // _runPreflight 内部已兜底；此处防御性双保险
    }
  }

  Future<void> _runPreflight() async {
    try {
      final view = _settings.read();
      if (!view.autoEnabled) return;
      // 仅 Wi-Fi 做直连预检：蜂窝直连大概率不通，预检纯耗时；蜂窝下的
      // 方向 A 由引擎/解析的失败兜底覆盖（onDirectFailure 不限网络）。
      if (!await _isOnWifiSafe()) return;
      final directOk = await _directCheckCached();
      if (directOk) {
        // 直连可用且手动代理开着 → 自动关闭（回落系统代理/直连）。
        // manual 本就关 → 理想状态，不动。
        if (view.proxyEnabled && _stablePeriodElapsed()) {
          await _settings.autoDisable();
          _lastAutoSwitchAt = _now();
          _events.add(const ProxyAutoDisabledEvent(source: 'preflight'));
        }
        return;
      }
      // 直连不可用：manual 开 → 已代理保持现状；manual 关且无系统代理
      // （effective DIRECT）→ 预检里直接做方向 A，不等真正失败。
      if (!view.proxyEnabled && _effectiveProxySetting() == 'DIRECT') {
        await _probeAndEnable(source: 'preflight');
      }
    } catch (_) {
      // 绝不抛
    }
  }

  /// 失败兜底（引擎退避重试/解析网络异常处接线）：当前生效 DIRECT 时
  /// 探测本地代理并自动启用。返回是否发生启用（测试/日志用）。
  ///
  /// 不限网络（蜂窝下同样 rescue）；代理已生效（manual 或系统）时直接
  /// 返回 false——那种失败与直连无关，探测无意义。
  Future<bool> onDirectFailure({String source = 'fallback'}) {
    final view = _settings.read();
    if (!view.autoEnabled) return Future.value(false);
    if (_effectiveProxySetting() != 'DIRECT') return Future.value(false);
    return _probeAndEnable(source: source);
  }

  /// 用户手动改代理设置（开关/地址）→ 稳定期立即解除（用户意志优先于
  /// 防抖）。由装配层的设置差分监听调用。
  void markUserTouched() {
    _lastAutoSwitchAt = null;
  }

  /// 探测 + 启用（单飞：并发触发共享同一轮探测）。
  Future<bool> _probeAndEnable({required String source}) {
    return _probeFlight ??= _doProbe(source).whenComplete(() {
      _probeFlight = null;
    });
  }

  Future<bool> _doProbe(String source) async {
    // 整体兜底不抛：失败兜底接线方多为 unawaited 调用（引擎退避/解析
    // 重试路径），未处理异步错误会击穿调用方（autoEnable 写 prefs 失败等）。
    try {
      // 冷却期内零探测；稳定期内不做反向自动切换（防 B→A 来回震荡）。
      if (_probeCooldownUntil != null &&
          _now().isBefore(_probeCooldownUntil!)) {
        return false;
      }
      if (!_stablePeriodElapsed()) return false;
      final view = _settings.read();
      // 候选：已保存生效地址优先（用户存了局域网网关也照探），然后本机
      // 常见端口；按 (host, port) 保序去重（Record 结构等价性）。
      final saved = parseProxyAddress(view.effectiveProxyAddress);
      final seen = <(String, int)>{};
      final candidates = <(String, int)>[
        if (saved != null && seen.add(saved)) saved,
        for (final port in _fallbackPorts)
          if (seen.add(('127.0.0.1', port))) ('127.0.0.1', port),
      ];
      for (final (host, port) in candidates) {
        // 阶段 1：TCP 短超时（本机端口未监听立即 RST；开放但非 HTTP 代理
        // 的端口由阶段 2 淘汰）。
        if (!await _tcpProbe(host, port)) continue;
        // 阶段 2：经该代理发真实 HTTPS 请求——CONNECT 隧道建立 + 上游
        // 可达才算通过；SOCKS-only 端口在此自然淘汰。
        if (!await _proxyConnectProbe(host, port)) continue;
        await _settings.autoEnable('$host:$port');
        _lastAutoSwitchAt = _now();
        _events.add(ProxyAutoEnabledEvent(
          address: '$host:$port',
          source: source,
        ));
        return true;
      }
      _probeCooldownUntil = _now().add(probeCooldown);
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 直连判定（TTL 缓存）：双主机都通才算可用——解析 CDN 通而视频 CDN
  /// 不通的「半通」环境下自动关代理会让下载立刻失败再触发启用，来回
  /// 震荡；双主机门槛把这种情况判为不可用（保持现状）。
  Future<bool> _directCheckCached() async {
    final cached = _directCache;
    if (cached != null &&
        _now()
            .isBefore(cached.at.add(cached.ok ? directOkTtl : directFailTtl))) {
      return cached.ok;
    }
    final results =
        await Future.wait(_directHosts.map((h) => _directHttpsProbe(h)));
    final ok = results.every((r) => r);
    _directCache = _DirectCheckResult(ok: ok, at: _now());
    return ok;
  }

  Future<bool> _isOnWifiSafe() async {
    final check = _isOnWifi;
    if (check == null) return false;
    try {
      return await check();
    } catch (_) {
      // fail-closed：方向 B 是「关代理」的破坏性动作，判定失败按非 Wi-Fi
      return false;
    }
  }

  bool _stablePeriodElapsed() {
    final last = _lastAutoSwitchAt;
    if (last == null) return true;
    return !_now().isBefore(last.add(minStablePeriod));
  }

  /// 测试注入：清空缓存/冷却/稳定期/单飞引用（不影响在途探测）。
  void debugReset() {
    _preflightFlight = null;
    _probeFlight = null;
    _probeCooldownUntil = null;
    _lastAutoSwitchAt = null;
    _directCache = null;
  }

  Future<void> dispose() => _events.close();
}

// ---------------------------------------------------------------------------
// 生产探测默认实现（测试经构造参数注入替换）
// ---------------------------------------------------------------------------

Future<bool> _defaultTcpProbe(
    String host, int port, Duration timeout) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> _defaultProxyConnectProbe(
    String host, int port, Duration timeout, String probeUrl) async {
  Dio? dio;
  try {
    dio = Dio(BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
      validateStatus: (_) => true, // 任意状态码都证明 CONNECT 隧道已建立
    ));
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (_) => 'PROXY $host:$port';
        return client;
      },
    );
    await dio.get<void>(probeUrl);
    return true;
  } catch (_) {
    return false;
  } finally {
    dio?.close();
  }
}

Future<bool> _defaultDirectHttpsProbe(
    String host, Duration timeout, String Function(String) probeUrlOf) async {
  Dio? dio;
  try {
    dio = Dio(BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
      validateStatus: (_) => true,
    ));
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        // 显式直连：绝不可用 createAppDio——那会吃 SystemProxy 缓存，
        // 已启用代理时会把「经代理可达」误判为「直连可用」（方向 B 误关）。
        client.findProxy = (_) => 'DIRECT';
        return client;
      },
    );
    await dio.get<void>(probeUrlOf(host));
    return true;
  } catch (_) {
    return false;
  } finally {
    dio?.close();
  }
}
