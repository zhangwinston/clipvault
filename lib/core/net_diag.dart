/// 网络诊断（设置页「诊断信息」区，§6.9 配套）：
/// 分层定位代理/TUN 环境下的失败环节——代理设置 → DNS → TCP → HTTPS，
/// 每阶段独立计时并给出结论数据（而非笼统「超时」）。
///
/// 背景：dart:io 自带 DNS 解析路径与 Happy Eyeballs 双栈竞速，与
/// TUN 类代理（sing-box/Clash VPN 模式）存在已知兼容毛刺——原生 App
/// （OkHttp/NSURLSession）正常而 Flutter App 超时的典型根因区。
/// 本工具把「超时」拆成可指认的阶段：DNS 劫持未接管（阶段1）/ TUN
/// 路由黑洞（阶段2）/ 代理链路 TLS 阻断（阶段3）。
library;

import 'dart:io';

import 'package:dio/dio.dart';

import 'app_strings.dart';
import 'app_http.dart';

/// 单阶段结果。
class NetDiagStep {
  const NetDiagStep({
    required this.stage,
    required this.ok,
    required this.elapsed,
    this.detail = '',
  });

  final String stage; // 展示名（AppStrings）
  final bool ok;
  final Duration elapsed;
  final String detail; // 结论数据（地址/状态码/错误摘要）
}

const String kDiagHost = 'cdn.syndication.twimg.com';
const int kDiagPort = 443;

/// 依次执行四阶段诊断（总时长上限约 30s：各阶段 6~8s 超时）。
Future<List<NetDiagStep>> runNetworkDiagnostics() async {
  final steps = <NetDiagStep>[];

  // ---- 阶段 0：当前生效代理 ----
  steps.add(NetDiagStep(
    stage: 'proxy',
    ok: true,
    elapsed: Duration.zero,
    detail: SystemProxy.proxySetting,
  ));

  // ---- 阶段 1：DNS（dart:io 自带解析路径——TUN 劫持是否接管的分水岭）----
  List<InternetAddress> addrs = const [];
  {
    final sw = Stopwatch()..start();
    try {
      addrs = await InternetAddress.lookup(kDiagHost)
          .timeout(const Duration(seconds: 8));
      steps.add(NetDiagStep(
        stage: 'dns',
        ok: addrs.isNotEmpty,
        elapsed: sw.elapsed,
        detail: _withRawNote(addrs.map((a) => a.address).join(' / ')),
      ));
    } catch (e) {
      steps.add(NetDiagStep(
        stage: 'dns',
        ok: false,
        elapsed: sw.elapsed,
        detail: _withRawNote(_brief(e)),
      ));
    }
  }

  // ---- 阶段 2：TCP 直连 443（TUN 路由是否黑洞；IPv6 优先的竞速毛刺在此显形）----
  var tcpOk = false;
  if (addrs.isNotEmpty) {
    final sw = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        addrs.first,
        kDiagPort,
        timeout: const Duration(seconds: 8),
      );
      socket.destroy();
      tcpOk = true;
      steps.add(NetDiagStep(
        stage: 'tcp',
        ok: true,
        elapsed: sw.elapsed,
        detail: _withRawNote('${addrs.first.address}:$kDiagPort'),
      ));
    } catch (e) {
      steps.add(NetDiagStep(
        stage: 'tcp',
        ok: false,
        elapsed: sw.elapsed,
        detail: _withRawNote(_brief(e)),
      ));
    }
  }

  // ---- 阶段 3：HTTPS（完整链路：TLS 握手 + 经代理 CONNECT 隧道 + 上游可达）----
  {
    final sw = Stopwatch()..start();
    try {
      final dio = createAppDio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        validateStatus: (code) => true, // 任意状态码都算链路通（4xx/5xx 也证明到达）
      ));
      final resp = await dio.get<void>('https://$kDiagHost/');
      dio.close();
      steps.add(NetDiagStep(
        stage: 'https',
        ok: true,
        elapsed: sw.elapsed,
        detail: 'HTTP ${resp.statusCode}',
      ));
    } catch (e) {
      steps.add(NetDiagStep(
        stage: 'https',
        ok: false,
        elapsed: sw.elapsed,
        detail: _brief(e),
      ));
    }
  }

  // tcp 未跑（DNS 已失败）时补一行说明，避免误读为「TCP 无问题」
  if (addrs.isEmpty && !tcpOk) {
    steps.add(const NetDiagStep(
      stage: 'tcp',
      ok: false,
      elapsed: Duration.zero,
      detail: 'DNS 未通过，跳过',
    ));
  }
  return steps;
}

/// 已设手动代理时给裸路径阶段追加标注（红属预期，以 HTTPS 为准）。
String _withRawNote(String detail) =>
    SystemProxy.hasProxy ? '$detail\n${AppStrings.diagRawStageNote}' : detail;

String _brief(Object e) {
  final s = e.toString();
  return s.length > 160 ? '${s.substring(0, 160)}…' : s;
}
