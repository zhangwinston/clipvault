/// VideoVariant estimatedBytes 溢出防护测试（DESIGN §5.1；B6）。
///
/// bitrate × durationMillis 的 int 乘法在 int64 域内会静默回绕，畸形/
/// 恶意响应（duration_millis 接近 int64 上限）会使回绕产物为负，违反
/// contracts/resolve.schema.json 的 estimatedBytes minimum: 0。
/// 此处验证安全乘法算法：恒非负、不回绕、常规值换算不变。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/parse/models.dart';

void main() {
  group('estimatedBytes 安全乘法（不回绕、恒非负）', () {
    test('常规值与既有换算一致（bitrate × durationMillis / 8000）', () {
      final v = VideoVariant.fromUrl(
        url: 'https://video.twimg.com/amplify_video/1/vid/avc1/728x720/a.mp4?tag=14',
        bitrate: 2176000,
        durationMillis: 15488,
      );
      expect(v.estimatedBytes, 2176000 * 15488 ~/ 8000);
      expect(v.estimatedBytes, 4212736);
    });

    test('durationMillis 为 int64 上限 → 钳制 int64 max，不回绕为负', () {
      final v = VideoVariant.fromUrl(
        url: 'https://video.twimg.com/a.mp4',
        bitrate: 2176000,
        durationMillis: 9223372036854775807,
      );
      expect(v.estimatedBytes, 9223372036854775807);
      expect(v.estimatedBytes, greaterThan(0));
    });

    test('bitrate 为 int64 上限 → 同样钳制', () {
      final v = VideoVariant.fromUrl(
        url: 'https://video.twimg.com/a.mp4',
        bitrate: 9223372036854775807,
        durationMillis: 15488,
      );
      expect(v.estimatedBytes, 9223372036854775807);
      expect(v.estimatedBytes, greaterThan(0));
    });

    test('两因子均在 2^53 边界但乘积超 int64 → double 域估算后钳 int64 max', () {
      final v = VideoVariant.fromUrl(
        url: 'https://video.twimg.com/a.mp4',
        bitrate: 9007199254740992, // 2^53（2^53 预检的边界值，不触发快路径）
        durationMillis: 9007199254740992,
      );
      expect(v.estimatedBytes, 9223372036854775807);
    });

    test('负因子 → 钳 0（schema minimum: 0，UI 不再显示负体积）', () {
      final negative = VideoVariant.fromUrl(
        url: 'https://video.twimg.com/a.mp4',
        bitrate: 2176000,
        durationMillis: -15488,
      );
      expect(negative.estimatedBytes, 0);
    });

    test('往返序列化保留非负估算值', () {
      final v = VideoVariant.fromUrl(
        url: 'https://video.twimg.com/amplify_video/1/vid/avc1/728x720/a.mp4?tag=14',
        bitrate: 2176000,
        durationMillis: 9223372036854775807,
      );
      final restored = VideoVariant.fromJson(v.toJson());
      expect(restored.estimatedBytes, greaterThan(0));
    });
  });
}
