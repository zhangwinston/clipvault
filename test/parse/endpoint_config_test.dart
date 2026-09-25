/// EndpointConfigRepository 测试（DESIGN §11.1）：
/// 内置加载 / 版本比较 / 原子替换 / 远端拉取失败回落（mock dio）/ drift 触发刷新。
/// SharedPreferences 用 mock 值、dio 用本地 stub 适配器——零真实网络与平台通道。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clipvault/parse/endpoint_config.dart';

import 'syndication_parser_test.dart' show StubAdapter, StubResponse;

/// 与 assets/config/endpoints.json 等价的 v1 内置配置（独立内联，便于构造变体）。
String bundledV1() => jsonEncode(<String, Object?>{
      'version': 1,
      'primary': <String, Object?>{
        'kind': 'syndication',
        'urlTemplate':
            'https://cdn.syndication.twimg.com/tweet-result?id={id}&lang={lang}&token={token}',
        'tokenAlgo': 'radix36-v1',
        'ua': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36',
        'timeoutMs': 6000,
      },
      'fallback': <String, Object?>{
        'kind': 'fxtwitter',
        'enabled': false,
        'urlTemplate': 'https://api.fxtwitter.com/status/{id}',
      },
      'driftGuard': <String, Object?>{
        'typenameEquals': 'Tweet',
        'requiredFields': <String>['user.screen_name'],
      },
    });

String remoteV(
  int version, {
  String urlTemplate = 'https://cdn.syndication.twimg.com/tweet-result-v2?id={id}',
  Object? timeoutMs = 8000,
}) =>
    jsonEncode(<String, Object?>{
      'version': version,
      'primary': <String, Object?>{
        'kind': 'syndication',
        'urlTemplate': urlTemplate,
        'tokenAlgo': 'radix36-v2',
        'ua': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/130',
        'timeoutMs': timeoutMs,
      },
    });

Future<SharedPreferences> mockPrefs({Map<String, Object> initial = const {}}) async {
  SharedPreferences.setMockInitialValues(initial);
  return SharedPreferences.getInstance();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('内置加载', () {
    test('读取真实 assets/config/endpoints.json（v1 预设，§6.7）', () async {
      final prefs = await mockPrefs();
      final repo = EndpointConfigRepository(
        dio: Dio(),
        prefs: prefs,
        assetLoader: (path) async => File(path).readAsString(),
      );

      final config = await repo.load();

      expect(config.version, 1);
      expect(config.primary.kind, 'syndication');
      expect(config.primary.urlTemplate, contains('{id}'));
      expect(config.primary.urlTemplate, startsWith('https://cdn.syndication.twimg.com/tweet-result'));
      expect(config.primary.tokenAlgo, 'radix36-v1');
      expect(config.primary.timeoutMs, 6000);
      expect(config.fallback.kind, 'fxtwitter');
      expect(config.fallback.enabled, isFalse);
      expect(config.fallback.urlTemplate, 'https://api.fxtwitter.com/status/{id}');
      expect(config.driftGuard.typenameEquals, 'Tweet');
      // mediaDetails 不在守卫范围：纯文本推文该字段整体缺失是合法形态（走 E05），
      // 守卫只做响应整体形状检查（error_codes.md 实现注记）。
      expect(config.driftGuard.requiredFields, ['user.screen_name']);
      expect(config.isUsable, isTrue);
      expect(repo.isLoaded, isTrue);
    });

    test('assetLoader 抛异常 → 内置代码兜底（离线可用优先）', () async {
      final prefs = await mockPrefs();
      final repo = EndpointConfigRepository(
        dio: Dio(),
        prefs: prefs,
        assetLoader: (path) async => throw Exception('asset missing'),
      );

      final config = await repo.load();

      expect(config.version, 1);
      expect(config.isUsable, isTrue);
      expect(config.primary.urlTemplate, contains('{id}'));
    });

    test('assetLoader 返回损坏 JSON → 内置代码兜底', () async {
      final prefs = await mockPrefs();
      final repo = EndpointConfigRepository(
        dio: Dio(),
        prefs: prefs,
        assetLoader: (path) async => '{not-json',
      );

      expect((await repo.load()).version, 1);
    });
  });

  group('版本比较与原子替换', () {
    test('prefs 缓存版本更高（v2 > 内置 v1）→ 采用缓存', () async {
      final prefs = await mockPrefs(initial: <String, Object>{
        kEndpointConfigJsonPrefKey: remoteV(2),
        kEndpointConfigVersionPrefKey: 2,
      });
      final repo = EndpointConfigRepository(
        dio: Dio(),
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
      );

      final config = await repo.load();

      expect(config.version, 2);
      expect(config.primary.timeoutMs, 8000);
      expect(config.primary.tokenAlgo, 'radix36-v2');
    });

    test('prefs 缓存版本不更高（v1 vs 内置 v1）→ 保持内置', () async {
      final prefs = await mockPrefs(initial: <String, Object>{
        kEndpointConfigJsonPrefKey: remoteV(1),
        kEndpointConfigVersionPrefKey: 1,
      });
      final repo = EndpointConfigRepository(
        dio: Dio(),
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
      );

      final config = await repo.load();

      expect(config.version, 1);
      expect(config.primary.timeoutMs, 6000); // 内置 v1 的超时
    });

    test('prefs 缓存损坏但版本更高 → 不选中（isUsable 校验兜底）', () async {
      final prefs = await mockPrefs(initial: <String, Object>{
        kEndpointConfigJsonPrefKey: '{broken',
        kEndpointConfigVersionPrefKey: 9,
      });
      final repo = EndpointConfigRepository(
        dio: Dio(),
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
      );

      expect((await repo.load()).version, 1);
    });
  });

  group('远端拉取（mock dio）', () {
    test('远端返回更高版本 → 原子替换并持久化到 prefs', () async {
      final prefs = await mockPrefs();
      final adapter = StubAdapter([StubResponse(200, remoteV(4))]);
      // 注意：不先 load()——load() 会触发 unawaited 后台远端拉取，消耗 stub。
      // 未加载时 current 回落内置 v1，版本比较语义一致。
      final repo = EndpointConfigRepository(
        dio: Dio()..httpClientAdapter = adapter,
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
        remoteUrl: 'https://rules.example.com/endpoints.json',
      );

      final replaced = await repo.refreshFromRemote();

      expect(replaced, isTrue);
      expect(repo.current.version, 4);
      expect(prefs.getInt(kEndpointConfigVersionPrefKey), 4);
      expect(prefs.getString(kEndpointConfigJsonPrefKey), isNotNull);
      // 持久化体可再解析且与 current 一致（原子替换后无半提交）。
      final persisted = EndpointConfig.tryParse(prefs.getString(kEndpointConfigJsonPrefKey));
      expect(persisted?.version, 4);
      expect(persisted?.primary.timeoutMs, 8000);
      expect(adapter.requestedUris, hasLength(1));
    });

    test('远端网络失败 → 回落保持现状，prefs 不变', () async {
      final prefs = await mockPrefs();
      final adapter = StubAdapter(
        [],
        // dio 5.x 的 DioException.connectionTimeout 要求显式 timeout；
        // 取值与 §6.1 的 6s 超时语义一致。
        errorToThrow: DioException.connectionTimeout(
          timeout: const Duration(milliseconds: 6000),
          requestOptions: RequestOptions(path: 'https://rules.example.com/endpoints.json'),
        ),
      );
      final repo = EndpointConfigRepository(
        dio: Dio()..httpClientAdapter = adapter,
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
        remoteUrl: 'https://rules.example.com/endpoints.json',
      );

      final replaced = await repo.refreshFromRemote();

      expect(replaced, isFalse);
      expect(repo.current.version, 1);
      expect(prefs.getInt(kEndpointConfigVersionPrefKey), isNull);
    });

    test('远端返回非 200 → 回落', () async {
      final prefs = await mockPrefs();
      final repo = EndpointConfigRepository(
        dio: Dio()..httpClientAdapter = StubAdapter([const StubResponse(503, 'unavailable')]),
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
        remoteUrl: 'https://rules.example.com/endpoints.json',
      );
      expect(await repo.refreshFromRemote(), isFalse);
      expect(repo.current.version, 1);
    });

    test('远端返回无效 JSON → 回落（防御性丢弃）', () async {
      final prefs = await mockPrefs();
      final repo = EndpointConfigRepository(
        dio: Dio()..httpClientAdapter = StubAdapter([const StubResponse(200, '<html>bad</html>')]),
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
        remoteUrl: 'https://rules.example.com/endpoints.json',
      );
      expect(await repo.refreshFromRemote(), isFalse);
      expect(repo.current.version, 1);
    });

    test('远端版本不高于当前 → 不替换（防降级）', () async {
      final prefs = await mockPrefs();
      final repo = EndpointConfigRepository(
        dio: Dio()..httpClientAdapter = StubAdapter([StubResponse(200, remoteV(1))]),
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
        remoteUrl: 'https://rules.example.com/endpoints.json',
      );

      expect(await repo.refreshFromRemote(), isFalse);
      expect(repo.current.version, 1);
      expect(prefs.getString(kEndpointConfigJsonPrefKey), isNull);
    });

    test('remoteUrl 为空 → 立即返回 false 且零请求（默认关闭，§6.7）', () async {
      final prefs = await mockPrefs();
      final adapter = StubAdapter(const []);
      final repo = EndpointConfigRepository(
        dio: Dio()..httpClientAdapter = adapter,
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
        remoteUrl: '  ',
      );

      expect(await repo.refreshFromRemote(), isFalse);
      expect(adapter.requestedUris, isEmpty);
    });

    test('load() 后台远端失败不影响返回值（离线可用）', () async {
      final prefs = await mockPrefs();
      final repo = EndpointConfigRepository(
        dio: Dio()
          ..httpClientAdapter = StubAdapter(
            [],
            errorToThrow: DioException.connectionTimeout(
              timeout: const Duration(milliseconds: 6000),
              requestOptions: RequestOptions(path: 'https://rules.example.com/endpoints.json'),
            ),
          ),
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
        remoteUrl: 'https://rules.example.com/endpoints.json',
      );

      final config = await repo.load();

      expect(config.version, 1);
      expect(config.primary.urlTemplate, contains('{id}'));
    });
  });

  group('EndpointDrift 触发刷新（§6.7：E07 驱动配置热更）', () {
    test('onEndpointDrift 请求远端一次并在版本更高时替换', () async {
      final prefs = await mockPrefs();
      final adapter = StubAdapter([StubResponse(200, remoteV(5))]);
      final repo = EndpointConfigRepository(
        dio: Dio()..httpClientAdapter = adapter,
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
        remoteUrl: 'https://rules.example.com/endpoints.json',
      );

      expect(await repo.onEndpointDrift(), isTrue);
      expect(repo.current.version, 5);
      expect(adapter.requestedUris, hasLength(1));
    });

    test('drift 刷新失败（远端不可用）→ 返回 false 且 current 不变', () async {
      final prefs = await mockPrefs();
      final adapter = StubAdapter(
        [],
        errorToThrow: DioException.receiveTimeout(
          timeout: const Duration(milliseconds: 6000),
          requestOptions: RequestOptions(path: 'https://rules.example.com/endpoints.json'),
        ),
      );
      final repo = EndpointConfigRepository(
        dio: Dio()..httpClientAdapter = adapter,
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
        remoteUrl: 'https://rules.example.com/endpoints.json',
      );

      expect(await repo.onEndpointDrift(), isFalse);
      expect(repo.current.version, 1);
    });
  });

  test('未 load 时 current 返回内置兜底', () async {
    final prefs = await mockPrefs();
    final repo = EndpointConfigRepository(
      dio: Dio(),
      prefs: prefs,
      assetLoader: (path) async => null,
    );
    expect(repo.current.version, 1);
    expect(repo.isLoaded, isFalse);
  });

  group('守卫默认值与内置兜底（mediaDetails 不在守卫范围）', () {
    test('builtIn() 的 requiredFields 不含 mediaDetails（与 endpoints.json 一致）', () {
      final config = EndpointConfig.builtIn();
      expect(config.driftGuard.requiredFields, ['user.screen_name']);
      expect(config.isUsable, isTrue);
    });

    test('driftGuard.requiredFields 缺失时回落默认守卫（不含 mediaDetails）', () {
      final parsed = EndpointConfig.tryParse(jsonEncode(<String, Object?>{
        'version': 3,
        'primary': <String, Object?>{
          'urlTemplate': 'https://cdn.syndication.twimg.com/tweet-result-v3?id={id}',
          'timeoutMs': 6000,
        },
        'driftGuard': <String, Object?>{'typenameEquals': 'Tweet'},
      }));
      expect(parsed, isNotNull);
      expect(parsed!.driftGuard.requiredFields, ['user.screen_name']);
    });
  });

  group('畸形远端配置（字段类型突变 → 配置无效，绝不逃逸异常）', () {
    test('tryParse：version 为字符串 → null（TypeError 不逃逸）', () {
      expect(EndpointConfig.tryParse('{"version": "2"}'), isNull);
    });

    test('tryParse：primary.urlTemplate 为数字 → null', () {
      expect(
        EndpointConfig.tryParse('{"version": 2, "primary": {"urlTemplate": 123}}'),
        isNull,
      );
    });

    test('tryParse：primary.timeoutMs 为字符串 → null', () {
      expect(
        EndpointConfig.tryParse(
          '{"version": 2, "primary": {"urlTemplate": "https://x/{id}", "timeoutMs": "6000"}}',
        ),
        isNull,
      );
    });

    test('refreshFromRemote：远端 version 为字符串 → 拒绝并保持现状', () async {
      final prefs = await mockPrefs();
      final repo = EndpointConfigRepository(
        dio: Dio()..httpClientAdapter = StubAdapter([const StubResponse(200, '{"version": "9"}')]),
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
        remoteUrl: 'https://rules.example.com/endpoints.json',
      );
      expect(await repo.refreshFromRemote(), isFalse);
      expect(repo.current.version, 1);
      expect(prefs.getInt(kEndpointConfigVersionPrefKey), isNull);
    });

    test('refreshFromRemote：远端 primary 整体为字符串 → 拒绝并保持现状', () async {
      final prefs = await mockPrefs();
      final repo = EndpointConfigRepository(
        dio: Dio()
          ..httpClientAdapter = StubAdapter([
            const StubResponse(200, '{"version": 9, "primary": "oops"}'),
          ]),
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
        remoteUrl: 'https://rules.example.com/endpoints.json',
      );
      expect(await repo.refreshFromRemote(), isFalse);
      expect(repo.current.version, 1);
      expect(prefs.getString(kEndpointConfigJsonPrefKey), isNull);
    });

    test('prefs 缓存字段类型突变 → 不选中（按无效处理）', () async {
      final prefs = await mockPrefs(initial: <String, Object>{
        // 版本号列合法但配置体 version 为字符串：tryParse 归 null，缓存不选中。
        kEndpointConfigJsonPrefKey: '{"version": "8"}',
        kEndpointConfigVersionPrefKey: 8,
      });
      final repo = EndpointConfigRepository(
        dio: Dio(),
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
      );
      expect((await repo.load()).version, 1);
    });
  });

  group('timeoutMs 合法域门禁（[500, 30000]，越界整套配置无效走回落）', () {
    test('0 / 负值 / 499 / 30001 → refreshFromRemote 拒绝且不持久化', () async {
      for (final timeoutMs in [0, -1, 499, 30001]) {
        final prefs = await mockPrefs();
        final repo = EndpointConfigRepository(
          dio: Dio()
            ..httpClientAdapter = StubAdapter([StubResponse(200, remoteV(9, timeoutMs: timeoutMs))]),
          prefs: prefs,
          assetLoader: (path) async => bundledV1(),
          remoteUrl: 'https://rules.example.com/endpoints.json',
        );
        expect(
          await repo.refreshFromRemote(),
          isFalse,
          reason: 'timeoutMs=$timeoutMs 应被拒绝（dio 超时被禁用/超长阻塞风险）',
        );
        expect(repo.current.version, 1, reason: 'timeoutMs=$timeoutMs');
        expect(repo.current.primary.timeoutMs, 6000, reason: 'timeoutMs=$timeoutMs');
        expect(prefs.getInt(kEndpointConfigVersionPrefKey), isNull, reason: 'timeoutMs=$timeoutMs');
      }
    });

    test('下界 500 与上界 30000 本身合法（闭区间）', () async {
      for (final timeoutMs in [500, 30000]) {
        final prefs = await mockPrefs();
        final repo = EndpointConfigRepository(
          dio: Dio()
            ..httpClientAdapter = StubAdapter([StubResponse(200, remoteV(9, timeoutMs: timeoutMs))]),
          prefs: prefs,
          assetLoader: (path) async => bundledV1(),
          remoteUrl: 'https://rules.example.com/endpoints.json',
        );
        expect(
          await repo.refreshFromRemote(),
          isTrue,
          reason: 'timeoutMs=$timeoutMs 在合法域内应被接受',
        );
        expect(repo.current.primary.timeoutMs, timeoutMs);
      }
    });

    test('isUsable 门禁同步作用于 prefs 缓存加载路径', () async {
      final prefs = await mockPrefs(initial: <String, Object>{
        kEndpointConfigJsonPrefKey: remoteV(9, timeoutMs: 0),
        kEndpointConfigVersionPrefKey: 9,
      });
      final repo = EndpointConfigRepository(
        dio: Dio(),
        prefs: prefs,
        assetLoader: (path) async => bundledV1(),
      );
      expect((await repo.load()).primary.timeoutMs, 6000); // 回落内置 v1
    });
  });
}
