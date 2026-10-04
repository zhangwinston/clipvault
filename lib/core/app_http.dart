/// 应用统一 HTTP 工厂：让 dio 跟随系统代理（Wi-Fi 手动代理）。
///
/// 为什么需要：dio 的 dart:io HttpClientAdapter 默认**不读** Android/iOS
/// 系统 Wi-Fi 代理设置（不像原生 OkHttp 自动跟随）——代理环境下 App 直连
/// x.com 被阻断 → 解析/下载全部超时（2026-09 用户实测反馈）。
///
/// 机制：
/// - [SystemProxy.refresh] 经 `clipvault/network` 通道读系统代理
///   （Android 读应用进程的 http.proxyHost/http.proxyPort JVM 属性；
///   iOS 读 CFNetworkCopySystemProxySettings 的 Wi-Fi 手动代理，见
///   DESIGN §6.9）；
/// - [createAppDio]/[configureProxy] 把缓存值接入 HttpClient.findProxy，
///   HTTPS 走 CONNECT 隧道由 dart:io 自动处理；
/// - 刷新时机：启动引导 + App 回前台（剪贴板观察者 resumed 分支顺带刷新）。
///
/// 已知限制（dart:io 层面）：不支持 PAC 自动配置脚本——PAC 用户请在系统
/// 改用手动代理，或使用 VPN 模式代理（TUN 层透明转发，无需本机制）。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart';

/// 系统代理解析（进程内缓存；[refresh] 后 [proxySetting] 生效）。
///
/// 优先级：**手动代理（设置页）> 系统代理（Wi-Fi 手动配置）> 直连**。
/// 手动代理存在的意义：移动网络下系统层没有代理设置（§6.9），
/// 用户代理客户端（sing-box/Clash 等）本地监听端口（如 2080/7890），
/// 填 `127.0.0.1:2080` 即可在任何网络走代理。
class SystemProxy {
  SystemProxy._();

  static const MethodChannel _channel = MethodChannel('clipvault/network');

  /// 缓存的系统代理指令（'PROXY host:port'）；null = 未取到。
  static String? _cached;

  /// 手动代理指令（设置页 proxyAddress 注入）；null = 未设置。
  static String? _manual;

  /// 就绪门闩：[refresh]（系统代理解析）与启动注入（main 的
  /// setManualAddress + [markReady]）任一完成即放行。图片等「随首帧
  /// 即发起」的请求经 [ready] 等待之——启动竞态期（设置未加载、通道
  /// 未返回）proxySetting 还是 DIRECT，代理环境下直连必失败，而失败
  /// 会被 ImageCache 永久滞留（见 RetryImage 注释），必须挡在前面。
  static Completer<void> _ready = Completer<void>();

  /// 代理解析/注入完成（幂等；2s 兜底超时防极端场景永久挂起）。
  static Future<void> get ready =>
      _ready.future.timeout(const Duration(seconds: 2), onTimeout: () {});

  /// 标记就绪（refresh 与启动注入完成时调用；幂等）。
  static void markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  /// 当前应使用的代理设置（findProxy 语法；手动 > 系统 > 直连）。
  static String get proxySetting => _manual ?? _cached ?? 'DIRECT';

  /// 是否解析到了代理（诊断/日志用）。
  static bool get hasProxy => _manual != null || _cached != null;

  /// 注入手动代理（'host:port'；空/非法 → 清除并回落系统/直连）。
  static void setManualAddress(String? raw) {
    final parsed = parseProxyAddress(raw);
    _manual = parsed == null ? null : 'PROXY ${parsed.$1}:${parsed.$2}';
  }

  /// 经平台通道刷新缓存。通道未实现（桌面/测试）或读取失败 → 直连，
  /// 绝不抛（网络增强能力，不影响主流程）。完成即 [markReady]。
  static Future<void> refresh() async {
    try {
      final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'getSystemProxy');
      final host = map?['host'];
      final port = map?['port'];
      if (host is String && host.isNotEmpty && port is int && port > 0) {
        _cached = 'PROXY $host:$port';
      } else {
        _cached = null;
      }
    } catch (_) {
      _cached = null;
    } finally {
      markReady();
    }
  }

  /// 测试注入（置空全部缓存；就绪门闩默认一并放行防测试挂起，
  /// 探测「未就绪」语义时传 ready: false）。
  static void debugReset({bool ready = true}) {
    _cached = null;
    _manual = null;
    _ready = Completer<void>();
    if (ready) markReady();
  }
}

/// 解析用户输入的代理地址（设置页与 [SystemProxy.setManualAddress] 共用）。
///
/// 接受 `host:port`（可带 `http://` 前缀；IPv6 字面量走最后一个冒号分割），
/// 端口域 1~65535；非法输入返回 null。
(String, int)? parseProxyAddress(String? raw) {
  if (raw == null) return null;
  var s = raw.trim();
  if (s.isEmpty) return null;
  for (final scheme in const ['http://', 'https://']) {
    if (s.startsWith(scheme)) s = s.substring(scheme.length);
  }
  s = s.replaceAll(RegExp(r'[/]$'), ''); // 容忍尾部斜杠
  final idx = s.lastIndexOf(':');
  if (idx <= 0 || idx == s.length - 1) return null;
  final host = s.substring(0, idx).replaceAll(RegExp(r'^\[|\]$'), '');
  final port = int.tryParse(s.substring(idx + 1));
  if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
  return (host, port);
}

/// 给已有 [dio] 接入系统代理（findProxy 回调读实时缓存）。
void configureProxy(Dio dio) {
  dio.httpClientAdapter = IOHttpClientAdapter(
    // dio 5.11：createHttpClient 全量接管 HttpClient 构造（非废弃的
    // onHttpClientCreate），此处复刻默认构造并注入 findProxy
    createHttpClient: () {
      final client = HttpClient();
      client.findProxy = (_) => SystemProxy.proxySetting;
      return client;
    },
  );
}

/// 应用统一 Dio 工厂：构造 + 代理接入（全项目 HTTP 出口集中于此）。
Dio createAppDio([BaseOptions? options]) {
  final dio = Dio(options);
  configureProxy(dio);
  return dio;
}
