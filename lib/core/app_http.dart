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

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart';

/// 系统代理解析（进程内缓存；[refresh] 后 [proxySetting] 生效）。
class SystemProxy {
  SystemProxy._();

  static const MethodChannel _channel = MethodChannel('clipvault/network');

  /// 缓存的代理指令（HttpClient.findProxy 语法，如 'PROXY 127.0.0.1:7890'）；
  /// null = 直连。
  static String? _cached;

  /// 当前应使用的代理设置（findProxy 语法；同步读缓存）。
  static String get proxySetting => _cached ?? 'DIRECT';

  /// 是否解析到了代理（诊断/日志用）。
  static bool get hasProxy => _cached != null;

  /// 经平台通道刷新缓存。通道未实现（iOS/桌面/测试）或读取失败 → 直连，
  /// 绝不抛（网络增强能力，不影响主流程）。
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
    }
  }

  /// 测试注入（置空缓存）。
  static void debugReset() => _cached = null;
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
