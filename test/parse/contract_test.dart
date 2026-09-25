/// 契约测试（DESIGN §11.1）：fixtures ↔ contracts/resolve.schema.json 双向断言。
///
/// 成功夹具（syndication_video_ok / syndication_multi_video / fxtwitter_status_ok）
/// 经对应 Parser 反序列化为 ResolveResult，toJson 后按 schema 校验；
/// 错误夹具（empty / photo_only / sensitive / 404_dogpage）断言七类错误分类
/// 与 contracts/error_codes.md 的码值一致（E01~E07 齐全性检查）。
/// schema 的 JSON Schema 特性以本文件内置的最小校验器子集支持
/// （type/enum/pattern/required/properties/additionalProperties/items/
/// minItems/minLength/minimum/exclusiveMinimum/$ref；format 仅作宽松忽略）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/core/error.dart';
import 'package:clipvault/parse/endpoint_config.dart';
import 'package:clipvault/parse/fxtwitter_parser.dart';
import 'package:clipvault/parse/models.dart';
import 'package:clipvault/parse/syndication_client.dart';
import 'package:clipvault/parse/syndication_parser.dart';

void main() {
  // 纯函数回放：dio 实例仅用于构造 Parser，不会被触达。
  final parser = SyndicationParser(
    client: SyndicationClient(dio: Dio()),
    config: EndpointConfig.builtIn(),
    langs: const ['en'],
  );
  final fxParser = FxTwitterParser(dio: Dio(), config: EndpointConfig.builtIn());

  late Map<String, dynamic> schema;

  setUpAll(() {
    final schemaFile = File('contracts/resolve.schema.json');
    expect(schemaFile.existsSync(), isTrue, reason: 'contracts/resolve.schema.json 缺失（S1 负责）');
    final dynamic decoded = jsonDecode(schemaFile.readAsStringSync());
    expect(decoded, isA<Map<String, dynamic>>());
    schema = decoded as Map<String, dynamic>;
  });

  group('成功夹具：反序列化为 ResolveResult 并通过 schema 校验', () {
    void expectSchemaValid(String fixtureName, Map<String, Object?> json) {
      final errors = <String>[];
      // 路径根标记用 raw 字符串书写：'$' 中裸 $ 会被当作插值起始（语法错误）。
      _validate(schema, json, r'$', errors, schema);
      expect(errors, isEmpty, reason: '$fixtureName 违反 resolve.schema.json：\n${errors.join('\n')}');
    }

    test('syndication_video_ok', () {
      final result = parser.parseResponse(
        SyndicationResponse(
          statusCode: 200,
          contentType: 'application/json; charset=utf-8',
          body: File('assets/fixtures/syndication_video_ok.json').readAsStringSync(),
        ),
        tweetId: '1790637656616943991',
      );
      expectSchemaValid('syndication_video_ok', result.toJson());
      _expectVariantInvariants(result.tweet.variants);
    });

    test('syndication_multi_video', () {
      final result = parser.parseResponse(
        SyndicationResponse(
          statusCode: 200,
          contentType: 'application/json; charset=utf-8',
          body: File('assets/fixtures/syndication_multi_video.json').readAsStringSync(),
        ),
        tweetId: '1798765432109876543',
      );
      expectSchemaValid('syndication_multi_video', result.toJson());
      _expectVariantInvariants(result.tweet.variants);
      expect(result.tweet.videoCount, greaterThanOrEqualTo(2));
    });

    test('fxtwitter_status_ok', () {
      final dynamic decoded = jsonDecode(File('assets/fixtures/fxtwitter_status_ok.json').readAsStringSync());
      final result = fxParser.parseBody(decoded as Map<String, dynamic>, tweetId: '1790637656616943991');
      expectSchemaValid('fxtwitter_status_ok', result.toJson());
      _expectVariantInvariants(result.tweet.variants);
    });
  });

  group('错误夹具：七类分类与 error_codes.md 契约一致', () {
    test('syndication_empty.json → TweetNotFound（E04）', () {
      expect(
        () => parser.parseResponse(
          SyndicationResponse(
            statusCode: 200,
            contentType: 'application/json; charset=utf-8',
            body: File('assets/fixtures/syndication_empty.json').readAsStringSync(),
          ),
          tweetId: '1790637656616943991',
        ),
        throwsA(isA<TweetNotFound>()),
      );
    });

    test('syndication_photo_only.json → NotVideoTweet（E05）', () {
      expect(
        () => parser.parseResponse(
          SyndicationResponse(
            statusCode: 200,
            contentType: 'application/json; charset=utf-8',
            body: File('assets/fixtures/syndication_photo_only.json').readAsStringSync(),
          ),
          tweetId: '1791234567890123456',
        ),
        throwsA(isA<NotVideoTweet>()),
      );
    });

    test('纯文本推文（mediaDetails 整体缺失，内联构造）→ NotVideoTweet（E05）', () {
      // error_codes.md 实现注记（2026-09-25 实测 id=20）：mediaDetails 缺失/
      // 空数组/无 video 条目三者统一归 E05，__typename 与 user.screen_name
      // 正常时不得误报 E07——与 Node 侧镜像 tools/check_contract.mjs 对齐。
      expect(
        () => parser.parseResponse(
          SyndicationResponse(
            statusCode: 200,
            contentType: 'application/json; charset=utf-8',
            body: jsonEncode(<String, dynamic>{
              '__typename': 'Tweet',
              'id_str': '20',
              'text': 'text only tweet',
              'created_at': '2024-05-15T06:57:40.000Z',
              'user': <String, dynamic>{
                'name': 'Text Only',
                'screen_name': 'textonly',
              },
            }),
          ),
          tweetId: '20',
        ),
        throwsA(isA<NotVideoTweet>()),
      );
    });

    test('syndication_sensitive.json → RestrictedContent（E06）', () {
      expect(
        () => parser.parseResponse(
          SyndicationResponse(
            statusCode: 200,
            contentType: 'application/json; charset=utf-8',
            body: File('assets/fixtures/syndication_sensitive.json').readAsStringSync(),
          ),
          tweetId: '1789012345678901234',
        ),
        throwsA(isA<RestrictedContent>()),
      );
    });

    test('syndication_404_dogpage.html → TweetNotFound（E04）', () {
      expect(
        () => parser.parseResponse(
          SyndicationResponse(
            statusCode: 404,
            contentType: 'text/html; charset=utf-8',
            body: File('assets/fixtures/syndication_404_dogpage.html').readAsStringSync(),
          ),
          tweetId: '1790637656616943991',
        ),
        throwsA(isA<TweetNotFound>()),
      );
    });

    test('contracts/error_codes.md 覆盖 E01~E07 全部码值', () {
      final md = File('contracts/error_codes.md');
      expect(md.existsSync(), isTrue, reason: 'contracts/error_codes.md 缺失（S1 负责）');
      final content = md.readAsStringSync();
      for (final code in ['E01', 'E02', 'E03', 'E04', 'E05', 'E06', 'E07']) {
        expect(content, contains(code), reason: 'error_codes.md 缺少 $code');
      }
    });
  });

  test('夹具目录无未接线文件（哨兵：新增夹具必须进入契约测试）', () {
    final handled = <String>{
      'syndication_video_ok.json',
      'syndication_multi_video.json',
      'syndication_photo_only.json',
      'syndication_404_dogpage.html',
      'syndication_empty.json',
      'syndication_sensitive.json',
      'fxtwitter_status_ok.json',
    };
    final dir = Directory('assets/fixtures');
    expect(dir.existsSync(), isTrue, reason: 'assets/fixtures/ 缺失（S1 负责）');
    final unhandled = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => !handled.contains(name))
        .toList();
    expect(unhandled, isEmpty, reason: '存在未接入契约测试的夹具：$unhandled');
  });
}

/// 变体不变量（schema 描述中的程序化断言：JSON Schema 无法表达排序）。
void _expectVariantInvariants(List<VideoVariant> variants) {
  expect(variants, isNotEmpty);
  for (final v in variants) {
    expect(v.contentType, VariantContentType.mp4);
    expect(v.bitrate, greaterThan(0));
    expect(v.qualityLabel, matches(RegExp(r'^(1080p \(Full HD\)|720p \(HD\)|480p \(SD\)|360p)$')));
  }
  for (var i = 1; i < variants.length; i++) {
    expect(
      variants[i - 1].bitrate,
      greaterThan(variants[i].bitrate),
      reason: 'variants 第 $i 档未按 bitrate 严格降序',
    );
  }
}

/// 最小 JSON Schema 校验器（子集），支持本契约用到的一切特性。
void _validate(
  Map<String, dynamic> schema,
  dynamic instance,
  String path,
  List<String> errors,
  Map<String, dynamic> root,
) {
  // $ref：仅支持 #/definitions/X 本地引用。
  final ref = schema[r'$ref'];
  if (ref is String) {
    if (ref.startsWith('#/definitions/')) {
      final name = ref.substring('#/definitions/'.length);
      final definitions = root['definitions'];
      if (definitions is Map<String, dynamic> && definitions[name] is Map<String, dynamic>) {
        _validate(definitions[name] as Map<String, dynamic>, instance, path, errors, root);
      } else {
        errors.add('$path: 未知 \$ref $ref');
      }
      return;
    }
    errors.add('$path: 不支持的 \$ref $ref');
    return;
  }

  // enum
  final enumValues = schema['enum'];
  if (enumValues is List && !enumValues.contains(instance)) {
    errors.add('$path: $instance 不在 enum $enumValues 内');
    return;
  }

  // type（支持联合类型数组，含 "null"）
  final type = schema['type'];
  if (type != null) {
    final allowed = type is List ? type : <dynamic>[type];
    if (!_typeMatches(allowed, instance)) {
      errors.add('$path: 实际类型 ${instance.runtimeType} 不满足 $allowed');
      return;
    }
  }

  if (instance is String) {
    final pattern = schema['pattern'];
    if (pattern is String && !RegExp(pattern).hasMatch(instance)) {
      errors.add('$path: "$instance" 不匹配 pattern $pattern');
    }
    final minLength = schema['minLength'];
    if (minLength is int && instance.length < minLength) {
      errors.add('$path: 长度 ${instance.length} < minLength $minLength');
    }
  }

  if (instance is num) {
    final minimum = schema['minimum'];
    if (minimum is num && instance < minimum) {
      errors.add('$path: $instance < minimum $minimum');
    }
    final exclusiveMinimum = schema['exclusiveMinimum'];
    if (exclusiveMinimum is num && instance <= exclusiveMinimum) {
      errors.add('$path: $instance <= exclusiveMinimum $exclusiveMinimum');
    }
  }

  if (instance is List) {
    final minItems = schema['minItems'];
    if (minItems is int && instance.length < minItems) {
      errors.add('$path: 元素数 ${instance.length} < minItems $minItems');
    }
    final items = schema['items'];
    if (items is Map<String, dynamic>) {
      for (var i = 0; i < instance.length; i++) {
        _validate(items, instance[i], '$path[$i]', errors, root);
      }
    }
  }

  if (instance is Map<String, dynamic>) {
    final required = schema['required'];
    if (required is List) {
      for (final key in required) {
        if (!instance.containsKey(key)) {
          errors.add('$path: 缺少必填字段 $key');
        }
      }
    }
    final properties = schema['properties'];
    if (properties is Map<String, dynamic>) {
      if (schema['additionalProperties'] == false) {
        for (final key in instance.keys) {
          if (!properties.containsKey(key)) {
            errors.add('$path: additionalProperties=false 不允许字段 "$key"');
          }
        }
      }
      instance.forEach((key, value) {
        final sub = properties[key];
        if (sub is Map<String, dynamic>) {
          _validate(sub, value, '$path.$key', errors, root);
        }
      });
    }
  }
}

bool _typeMatches(List<dynamic> allowed, dynamic instance) {
  for (final t in allowed) {
    switch (t) {
      case 'object' when instance is Map:
        return true;
      case 'array' when instance is List:
        return true;
      case 'string' when instance is String:
        return true;
      case 'integer' when instance is int:
        return true;
      case 'number' when instance is num:
        return true;
      case 'boolean' when instance is bool:
        return true;
      case 'null' when instance == null:
        return true;
    }
  }
  return false;
}
