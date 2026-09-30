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
