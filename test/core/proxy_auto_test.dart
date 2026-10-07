/// 自动代理调节协调器测试（DESIGN §6.9「双向自动调节」）。
///
/// 全离线：注入假设置/假时钟/脚本化探测函数断言状态机（两阶段淘汰 /
/// 候选优先级 / 单飞 / 冷却 / TTL 缓存 / 稳定期 / 门条件 / 预检预算）；
/// 另配真实回环用例（本地 origin + 字节管道正向代理，探测 URL 覆写为
/// http 绕开公网 TLS）验证生产探测函数链路。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/core/app_http.dart' show SystemProxy;
import 'package:clipvault/core/proxy_auto.dart';

// ---------------------------------------------------------------------------
// 测试基建
// ---------------------------------------------------------------------------

/// 假设置：可编程视图 + 记录 autoEnable/autoDisable 调用。
class FakeSettings implements ProxyAutoSettings {
  FakeSettings({
    this.autoEnabled = true,
    this.proxyEnabled = false,
    this.effectiveProxyAddress = '127.0.0.1:2080',
  });

  bool autoEnabled;
  bool proxyEnabled;
  String effectiveProxyAddress;
  final List<String> enabledAddresses = <String>[];
  int disableCount = 0;

  @override
  ProxyAutoSettingsView read() => ProxyAutoSettingsView(
        autoEnabled: autoEnabled,
        proxyEnabled: proxyEnabled,
        effectiveProxyAddress: effectiveProxyAddress,
      );

  @override
  Future<void> autoEnable(String address) async {
    enabledAddresses.add(address);
    proxyEnabled = true;
    effectiveProxyAddress = address;
  }

  @override
  Future<void> autoDisable() async {
    disableCount++;
    proxyEnabled = false;
  }
}

/// 假时钟：手动推进（冷却 / TTL / 稳定期确定性断言）。
class FakeClock {
  DateTime _now = DateTime(2026, 10, 7, 12);

  DateTime now() => _now;

  void advance(Duration d) => _now = _now.add(d);
}

/// 可变持有者（让闭包注入的值在测试中可改）。
class Holder<T> {
  Holder(this.value);

  T value;
}

/// 冲刷异步事件送达：广播流的监听交付不保证在协调器 API 的 await 返回
/// 前完成（事件 add 在内部链路完成之前，交付微任务的调度次序与 API
/// 返回链路无契约），断言事件前列先冲刷。
Future<void> flushEvents() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 脚本化探测：记录调用序列 + 可编程结果（默认全 false；FutureOr 签名
/// 兼容同步/异步脚本——异步用于单飞与预算用例的时序控制）。
class ProbeScript {
  final List<String> calls = <String>[];
  FutureOr<bool> Function(String host, int port)? tcp;
  FutureOr<bool> Function(String host, int port)? connect;
  FutureOr<bool> Function(String host)? direct;

  Future<bool> tcpProbe(String host, int port) async {
    calls.add('tcp $host:$port');
    return await (tcp?.call(host, port) ?? false);
  }

  Future<bool> connectProbe(String host, int port) async {
    calls.add('connect $host:$port');
    return await (connect?.call(host, port) ?? false);
  }

  Future<bool> directProbe(String host) async {
    calls.add('direct $host');
    return await (direct?.call(host) ?? false);
  }

  int countOf(String prefix) =>
      calls.where((c) => c.startsWith(prefix)).length;
}

/// 组装被测协调器（默认候选 = 保存地址 127.0.0.1:2080 + fallback 7890）。
ProxyAutoCoordinator buildCoordinator(
  FakeSettings settings,
  FakeClock clock,
  ProbeScript probes, {
  Holder<bool>? wifi,
  Holder<String>? effective,
  List<int> fallbackPorts = const [7890],
  List<String> directHosts = const ['a.test', 'b.test'],
  Duration? preflightBudget,
}) {
  final w = wifi ?? Holder<bool>(true);
  final e = effective ?? Holder<String>('DIRECT');
  return ProxyAutoCoordinator(
    settings: settings,
    now: clock.now,
    isOnWifi: () async => w.value,
    effectiveProxySetting: () => e.value,
    fallbackPorts: fallbackPorts,
    directHosts: directHosts,
    preflightBudget: preflightBudget ?? const Duration(seconds: 3),
    tcpProbe: probes.tcpProbe,
    proxyConnectProbe: probes.connectProbe,
    directHttpsProbe: probes.directProbe,
  );
}

/// 字节管道正向代理（http 绝对 URI 请求行 → 连源站双向原样转发）：
/// 与 test/download/proxy_resume_test.dart 的 MiniForwardProxy 同构，
/// 复制精简版以维持各测试文件自带 fakes 的惯例。
class LoopbackHttpProxy {
  late final ServerSocket _socket;
  int connections = 0;

  Future<void> start() async {
    _socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket.listen((client) {
      connections++;
      Socket? origin;
      var connected = false;
      var pending = <int>[];
      client.listen(
        (data) async {
          if (connected) {
            origin?.add(data);
            return;
          }
          pending.addAll(data);
          final text = latin1.decode(pending);
          final eol = text.indexOf('\r\n');
          if (eol < 0) return;
          final reqLine = text.substring(0, eol);
          final uri = Uri.parse(reqLine.split(' ')[1]);
          connected = true;
          try {
            origin = await Socket.connect(uri.host, uri.port);
          } catch (_) {
            client.destroy();
            return;
          }
          origin!.write(text);
          origin!.listen(
            (od) => client.add(od),
            onDone: () => client.close(),
            onError: (_) => client.destroy(),
          );
        },
        onDone: () => origin?.close(),
        onError: (_) => client.destroy(),
        cancelOnError: true,
      );
    }, onError: (_) {});
  }

  String get address => '127.0.0.1:${_socket.port}';

  Future<void> close() => _socket.close();
}

void main() {
  setUp(SystemProxy.debugReset);
  tearDown(SystemProxy.debugReset);

  group('门条件', () {
    test('总开关关闭：preflight 与 onDirectFailure 全零成本', () async {
      final settings = FakeSettings(autoEnabled: false);
      final probes = ProbeScript();
      final c = buildCoordinator(settings, FakeClock(), probes);
      addTearDown(c.dispose);

      await c.preflight();
      expect(await c.onDirectFailure(), isFalse);
      expect(probes.calls, isEmpty);
    });

    test('代理已生效（非 DIRECT）：onDirectFailure 不探测', () async {
      final settings = FakeSettings();
      final probes = ProbeScript();
      final c = buildCoordinator(settings, FakeClock(), probes,
          effective: Holder<String>('PROXY 1.2.3.4:1'));
      addTearDown(c.dispose);

      expect(await c.onDirectFailure(), isFalse);
      expect(probes.calls, isEmpty);
    });

    test('非 Wi-Fi：preflight 不做直连探测（方向 A 由失败兜底覆盖）', () async {
      final settings = FakeSettings(proxyEnabled: true);
      final probes = ProbeScript();
      final c = buildCoordinator(
          settings, FakeClock(), probes, wifi: Holder<bool>(false));
      addTearDown(c.dispose);

      await c.preflight();
      expect(probes.calls, isEmpty);
      expect(settings.disableCount, 0);
    });

    test('总开关关闭后再开启：preflight 不因单飞残留而哑火（回归）', () async {
      final settings = FakeSettings(autoEnabled: false);
      final probes = ProbeScript()..direct = (_) => true;
      final c = buildCoordinator(settings, FakeClock(), probes);
      addTearDown(c.dispose);

      // 关闭态：同步提前返回路径，曾因 finally 早于 ??= 清空引用而留下
      // 已完成的单飞 future，此后 preflight 永远复用旧结果
      await c.preflight();
      expect(probes.calls, isEmpty);

      settings.autoEnabled = true;
      settings.proxyEnabled = true;
      await c.preflight();
      expect(probes.countOf('direct'), 2); // 单飞已清理，第二次真正执行
      expect(settings.disableCount, 1);
    });
  });

  group('方向 A：候选探测与自动启用', () {
    test('候选优先级：保存地址通过即启用，fallback 端口不再探', () async {
      final settings = FakeSettings(effectiveProxyAddress: '127.0.0.1:9999');
      // 探测脚本用独立赋值语句：级联段接函数字面量 RHS 存在解析歧义
      final probes = ProbeScript();
      probes.tcp = (String host, int port) => port == 9999;
      probes.connect = (String host, int port) => port == 9999;
      final c = buildCoordinator(settings, FakeClock(), probes);
      addTearDown(c.dispose);

      expect(await c.onDirectFailure(source: 'download'), isTrue);
      expect(settings.enabledAddresses, <String>['127.0.0.1:9999']);
      expect(probes.calls, <String>[
        'tcp 127.0.0.1:9999',
        'connect 127.0.0.1:9999',
      ]);
    });

    test('两阶段淘汰：TCP 开放但 CONNECT 不通 → 不启用 + 冷却', () async {
      final settings = FakeSettings();
      final probes = ProbeScript();
      probes.tcp = (_, _) => true;
      probes.connect = (_, _) => false;
      final clock = FakeClock();
      final c = buildCoordinator(settings, clock, probes);
      addTearDown(c.dispose);

      expect(await c.onDirectFailure(), isFalse);
      expect(settings.enabledAddresses, isEmpty);
      // 保存地址(2080) 与 fallback(7890) 都走到 CONNECT 阶段
      expect(probes.countOf('connect'), 2);

      // 冷却期内（59s）再触发：零新增探测
      final callsAfterFirst = probes.calls.length;
      clock.advance(const Duration(seconds: 59));
      expect(await c.onDirectFailure(), isFalse);
      expect(probes.calls.length, callsAfterFirst);

      // 61s 后恢复探测（仍失败但不影响「恢复」断言）
      clock.advance(const Duration(seconds: 2));
      expect(await c.onDirectFailure(), isFalse);
      expect(probes.calls.length, greaterThan(callsAfterFirst));
    });

    test('单飞：并发两次触发共享一轮探测，只启用一次', () async {
      final settings = FakeSettings();
      final gate = Completer<void>();
      final probes = ProbeScript();
      probes.tcp = (_, _) async {
        await gate.future;
        return true;
      };
      probes.connect = (_, _) => true;
      final c = buildCoordinator(settings, FakeClock(), probes);
      addTearDown(c.dispose);

      final r1 = c.onDirectFailure();
      final r2 = c.onDirectFailure();
      await Future<void>.delayed(Duration.zero);
      expect(probes.countOf('tcp'), 1); // 第二次触发复用在途探测

      gate.complete();
      expect(await r1, isTrue);
      expect(await r2, isTrue);
      expect(settings.enabledAddresses, hasLength(1));
    });
  });

  group('方向 B：Wi-Fi 直连预检', () {
    test('直连可用（双主机全通）且 manual 开 → 自动关闭 + 事件', () async {
      final settings = FakeSettings(proxyEnabled: true);
      final probes = ProbeScript()..direct = (_) => true;
      final c = buildCoordinator(settings, FakeClock(), probes);
      addTearDown(c.dispose);
      final events = <ProxyAutoEvent>[];
      c.events.listen(events.add);

      await c.preflight();
      expect(settings.disableCount, 1);
      expect(settings.proxyEnabled, isFalse);
      await flushEvents();
      expect(events, hasLength(1));
      expect(events.single, isA<ProxyAutoDisabledEvent>());
    });

    test('直连可用但 manual 本就关 → 不动', () async {
      final settings = FakeSettings(proxyEnabled: false);
      final probes = ProbeScript()..direct = (_) => true;
      final c = buildCoordinator(settings, FakeClock(), probes);
      addTearDown(c.dispose);

      await c.preflight();
      expect(settings.disableCount, 0);
    });

    test('双主机一通一断 → 判不可用：不关闭，manual 开时也不探测候选', () async {
      final settings = FakeSettings(proxyEnabled: true);
      final probes = ProbeScript()..direct = (host) => host == 'a.test';
      final c = buildCoordinator(settings, FakeClock(), probes);
      addTearDown(c.dispose);

      await c.preflight();
      expect(settings.disableCount, 0); // 半通不算直连可用
      expect(probes.countOf('tcp'), 0); // manual 开 → 保持现状，不探测
    });

    test('直连不可用 + manual 关 + DIRECT → 预检里预探测启用', () async {
      final settings = FakeSettings(proxyEnabled: false);
      final probes = ProbeScript();
      probes.direct = (_) => false;
      probes.tcp = (_, _) => true;
      probes.connect = (_, _) => true;
      final c = buildCoordinator(settings, FakeClock(), probes);
      addTearDown(c.dispose);

      await c.preflight();
      expect(settings.enabledAddresses, <String>['127.0.0.1:2080']);
    });

    test('直连判定 TTL：成功 5min 内零重复探测，过期重探', () async {
      final settings = FakeSettings(proxyEnabled: true);
      final probes = ProbeScript()..direct = (_) => true;
      final clock = FakeClock();
      final c = buildCoordinator(settings, clock, probes);
      addTearDown(c.dispose);

      await c.preflight();
      expect(probes.countOf('direct'), 2); // 双主机
      await c.preflight();
      expect(probes.countOf('direct'), 2); // TTL 内复用结论
      clock.advance(const Duration(minutes: 5, seconds: 1));
      await c.preflight();
      expect(probes.countOf('direct'), 4); // 过期重探
    });
  });

  group('稳定期（防来回震荡）', () {
    test('自动关闭后 2min 内反向自动启用被抑制，期满放行', () async {
      final settings = FakeSettings(proxyEnabled: true);
      final probes = ProbeScript()..direct = (_) => true;
      final clock = FakeClock();
      final effective = Holder<String>('PROXY 127.0.0.1:2080');
      final c = buildCoordinator(settings, clock, probes,
          effective: effective);
      addTearDown(c.dispose);

      await c.preflight();
      expect(settings.disableCount, 1);

      // 网络变化：直连断了（effective 回到 DIRECT），想反向启用
      effective.value = 'DIRECT';
      probes.direct = (_) => false;
      probes.tcp = (_, _) => true;
      probes.connect = (_, _) => true;
      clock.advance(const Duration(seconds: 30));
      expect(await c.onDirectFailure(), isFalse); // 稳定期内抑制
      expect(probes.countOf('tcp'), 0);

      clock.advance(const Duration(minutes: 2));
      expect(await c.onDirectFailure(), isTrue); // 期满放行
      expect(settings.enabledAddresses, <String>['127.0.0.1:2080']);
    });

    test('用户手动改设置 → 稳定期立即解除', () async {
      final settings = FakeSettings(proxyEnabled: true);
      final probes = ProbeScript()..direct = (_) => true;
      final effective = Holder<String>('PROXY 127.0.0.1:2080');
      final c = buildCoordinator(settings, FakeClock(), probes,
          effective: effective);
      addTearDown(c.dispose);

      await c.preflight();
      expect(settings.disableCount, 1);

      effective.value = 'DIRECT';
      probes.direct = (_) => false;
      probes.tcp = (_, _) => true;
      probes.connect = (_, _) => true;
      c.markUserTouched(); // 装配层的设置差分监听在手动改时调用
      expect(await c.onDirectFailure(), isTrue);
    });
  });

  group('preflight 预算', () {
    test('直连探测挂死时 preflight 在预算内返回，工作后台续跑', () async {
      final settings = FakeSettings(proxyEnabled: false);
      final gate = Completer<void>();
      final probes = ProbeScript();
      probes.direct = (_) async {
        await gate.future;
        return false;
      };
      probes.tcp = (_, _) => true;
      probes.connect = (_, _) => true;
      final c = buildCoordinator(settings, FakeClock(), probes,
          preflightBudget: const Duration(milliseconds: 100));
      addTearDown(c.dispose);

      final sw = Stopwatch()..start();
      await c.preflight();
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));

      // 放行挂死的直连探测：后台飞行继续完成并启用
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(settings.enabledAddresses, <String>['127.0.0.1:2080']);
    });
  });

  group('真实回环（生产探测函数链路）', () {
    test('转发代理在保存地址上 → 两阶段验证通过并启用', () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final originSub = origin.listen((req) async {
        req.response.statusCode = 200;
        await req.response.close();
      });
      addTearDown(() async {
        await originSub.cancel();
        await origin.close(force: true);
      });
      final proxy = LoopbackHttpProxy();
      await proxy.start();
      addTearDown(proxy.close);

      final settings = FakeSettings(
        proxyEnabled: false,
        effectiveProxyAddress: proxy.address,
      );
      final c = ProxyAutoCoordinator(
        settings: settings,
        now: FakeClock().now,
        isOnWifi: () async => true,
        fallbackPorts: const [], // 候选只有保存地址（回环端口由脚本注入）
        connectProbeUrl: 'http://127.0.0.1:${origin.port}/probe',
        connectProbeTimeout: const Duration(seconds: 2),
        tcpProbeTimeout: const Duration(seconds: 1),
      );
      addTearDown(c.dispose);
      final events = <ProxyAutoEvent>[];
      c.events.listen(events.add);

      expect(await c.onDirectFailure(), isTrue);
      expect(settings.enabledAddresses, <String>[proxy.address]);
      await flushEvents();
      expect(events.single, isA<ProxyAutoEnabledEvent>());
      expect(proxy.connections, greaterThanOrEqualTo(1));
    });

    test('TCP 开放但非 HTTP 代理（收连即毁）→ 阶段 2 淘汰', () async {
      var accepts = 0;
      final bare = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sub = bare.listen((s) {
        accepts++;
        s.destroy();
      });
      addTearDown(() async {
        await sub.cancel();
        await bare.close();
      });

      final settings = FakeSettings(
        proxyEnabled: false,
        effectiveProxyAddress: '127.0.0.1:${bare.port}',
      );
      final c = ProxyAutoCoordinator(
        settings: settings,
        now: FakeClock().now,
        fallbackPorts: const [],
        connectProbeUrl: 'http://127.0.0.1:1/probe',
        connectProbeTimeout: const Duration(milliseconds: 800),
        tcpProbeTimeout: const Duration(seconds: 1),
      );
      addTearDown(c.dispose);

      expect(await c.onDirectFailure(), isFalse);
      expect(accepts, greaterThanOrEqualTo(1)); // TCP 阶段确实探到开放
      expect(settings.enabledAddresses, isEmpty);
    });
  });
}
