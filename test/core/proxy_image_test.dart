/// ProxyNetworkImage（缩略图回归修复，2026-09-30）单元测试：
/// key 相等性/哈希（ImageCache 命中前提）与 obtainKey 同步返回。
///
/// 网络路径（_load 经共享 Dio 拉取）不做离线断言——代理行为已由
/// app_http_test 与 settings_controller_test 覆盖，此处只锁缓存键语义。
library;

import 'package:flutter/painting.dart' show ImageConfiguration;
import 'package:flutter_test/flutter_test.dart';
import 'package:clipvault/core/proxy_image.dart';

void main() {
  test('相同 URL+scale 视为相等（ImageCache 复用同 key）', () {
    const a = ProxyNetworkImage('https://pbs.twimg.com/x.jpg');
    const b = ProxyNetworkImage('https://pbs.twimg.com/x.jpg');
    expect(a == b, isTrue);
    expect(a.hashCode, b.hashCode);
  });

  test('URL 或 scale 不同则不等', () {
    const a = ProxyNetworkImage('https://a/x.jpg');
    const b = ProxyNetworkImage('https://b/x.jpg');
    const c = ProxyNetworkImage('https://a/x.jpg', scale: 2.0);
    expect(a == b, isFalse);
    expect(a == c, isFalse);
    expect(a.hashCode == b.hashCode, isFalse);
  });

  test('obtainKey 同步返回自身（SynchronousFuture，无额外异步开销）', () async {
    const img = ProxyNetworkImage('https://a/x.jpg');
    final key = await img.obtainKey(ImageConfiguration.empty);
    expect(identical(key, img), isTrue);
  });
}
