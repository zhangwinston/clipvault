/// 系统代理接入测试（DESIGN §6.9）：通道 mock + 缓存语义 + Dio 装配。
library;

import 'package:dio/io.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/core/app_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(SystemProxy.debugReset);

  test('通道返回 host/port → 缓存 PROXY 指令；findProxy 语法正确', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('clipvault/network'),
            (call) async {
      expect(call.method, 'getSystemProxy');
      return {'host': '127.0.0.1', 'port': 7890};
    });
    await SystemProxy.refresh();
    expect(SystemProxy.hasProxy, isTrue);
    expect(SystemProxy.proxySetting, 'PROXY 127.0.0.1:7890');
  });

  test('通道返回 null / 非法值 → 直连；通道缺失 → 直连且不抛', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('clipvault/network'),
        (call) async => null);
    await SystemProxy.refresh();
    expect(SystemProxy.hasProxy, isFalse);
    expect(SystemProxy.proxySetting, 'DIRECT');

    // 非法端口
    messenger.setMockMethodCallHandler(const MethodChannel('clipvault/network'),
        (call) async => {'host': 'x', 'port': 0});
    await SystemProxy.refresh();
    expect(SystemProxy.hasProxy, isFalse);

    // 通道未实现（iOS/桌面）：MissingPluginException → 直连
    messenger.setMockMethodCallHandler(
        const MethodChannel('clipvault/network'), null);
    await SystemProxy.refresh();
    expect(SystemProxy.proxySetting, 'DIRECT');
  });

  test('createAppDio 接入 IOHttpClientAdapter（findProxy 读实时缓存）',
      () async {
    final dio = createAppDio();
    expect(dio.httpClientAdapter, isA<IOHttpClientAdapter>());

    // 刷新缓存后新请求走新值（findProxy 闭包读静态缓存，无重新装配需要）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('clipvault/network'),
            (call) async => {'host': '192.168.1.5', 'port': 8888});
    await SystemProxy.refresh();
    expect(SystemProxy.proxySetting, 'PROXY 192.168.1.5:8888');

    dio.close();
  });

  group('手动代理（§6.9 移动网络场景）：优先级与地址解析', () {
    test('parseProxyAddress：合法/非法输入', () {
      expect(parseProxyAddress('127.0.0.1:2080'), ('127.0.0.1', 2080));
      expect(parseProxyAddress('http://127.0.0.1:7890'), ('127.0.0.1', 7890));
      expect(parseProxyAddress(' 192.168.1.5:8888/'), ('192.168.1.5', 8888));
      expect(parseProxyAddress('[::1]:2080'), ('::1', 2080));
      expect(parseProxyAddress(''), isNull);
      expect(parseProxyAddress(null), isNull);
      expect(parseProxyAddress('abc'), isNull);
      expect(parseProxyAddress('host:'), isNull);
      expect(parseProxyAddress(':8080'), isNull);
      expect(parseProxyAddress('host:0'), isNull);
      expect(parseProxyAddress('host:65536'), isNull);
      expect(parseProxyAddress('host:abc'), isNull);
    });

    test('优先级：手动 > 系统 > 直连；非法手动被忽略', () async {
      final messenger = TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('clipvault/network'),
          (call) async => {'host': '10.0.0.2', 'port': 8888});
      await SystemProxy.refresh();
      expect(SystemProxy.proxySetting, 'PROXY 10.0.0.2:8888');

      SystemProxy.setManualAddress('127.0.0.1:2080');
      expect(SystemProxy.proxySetting, 'PROXY 127.0.0.1:2080'); // 手动优先

      SystemProxy.setManualAddress('not-valid'); // 非法 → 清除回落系统
      expect(SystemProxy.proxySetting, 'PROXY 10.0.0.2:8888');

      SystemProxy.setManualAddress(''); // 清空 → 系统
      expect(SystemProxy.proxySetting, 'PROXY 10.0.0.2:8888');
    });
  });

  test('createAppDio 透传 BaseOptions（超时等配置不丢）', () {
    final dio = createAppDio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    ));
    expect(dio.options.connectTimeout, const Duration(seconds: 15));
    expect(dio.options.receiveTimeout, const Duration(seconds: 60));
    dio.close();
  });
}
