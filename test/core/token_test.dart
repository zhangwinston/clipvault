import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/core/token.dart';

/// getToken 端到端测试（DESIGN §11.1）：
/// 已知向量硬编码断言（评委复现值）+ 语料边界行 + token 字符集性质。
void main() {
  group('已知向量（DESIGN §6.2 评委复现值）', () {
    test('1790637656616943991 → 4c9gcitu1vq', () {
      const String id = '1790637656616943991';
      final TokenParts parts = computeToken(id);
      expect(parts.radix36, '4c9.gcitu1vq'); // 中间值（实测）
      expect(parts.token, '4c9gcitu1vq');
      expect(getToken(id), '4c9gcitu1vq');
    });

    test('id=0：radix36 为 "0"，剥离后 token 为空串', () {
      expect(getToken('0'), '');
      expect(computeToken('0').radix36, '0');
    });
  });

  group('语料边界行（token_corpus.csv 边界向量，Node V8 实测）', () {
    final List<(String, String)> vectors = <(String, String)>[
      ('0', ''),
      ('1', 'bhi2ay3f28n'),
      ('2', 'mz4lw6u4h9'), // radix36=0.000000000mz04lw6u4h9：剥离步移除全部 '0'（取自 csv token 列）
      ('3', 'ygi6wua96pp'),
      ('9007199254740991', 'saoujnx4are'), // 2^53 - 1
      ('9007199254740992', 'saoujnx4as'), // 2^53
      ('9007199254740993', 'saoujnx4as'), // 2^53 + 1：舍入为 2^53，同 token
      ('1000000000000000000', '2f9lc2ug9mm'), // 1e18 采样下界
      ('1999999999999999999', '4uj6o5owj98'),
      ('2000000000000000000', '4uj6o5owj98'), // 2e18 上界（与上一行同 double）
    ];

    test('逐条断言', () {
      for (final (id, expected) in vectors) {
        expect(getToken(id), expected, reason: 'id=$id 期望 $expected');
      }
    });

    test('超 2^53 的 ID 存在 IEEE754 双精度舍入（9007199254740993 ≡ 9007199254740992）',
        () {
      expect(getToken('9007199254740993'), getToken('9007199254740992'));
    });
  });

  group('token 字符集性质', () {
    test('剥离后不含 "0" 与 "."（2010-2026 雪花 ID 区间确定性采样）', () {
      // 覆盖区间端点与系统性步进，确定性无需 PRNG
      for (int i = 0; i < 200; i++) {
        final BigInt id =
            BigInt.from(1000000000000000000) + BigInt.from(i * 5000000000000001);
        final String token = getToken(id.toString());
        expect(token, matches(RegExp(r'^[1-9a-z]*$')),
            reason: 'id=$id token=$token 含非法字符');
      }
    });

    test('非法输入抛 FormatException（调用方须先过 url_extract 校验）', () {
      expect(() => getToken('abc'), throwsFormatException);
      expect(() => getToken(''), throwsFormatException);
    });
  });
}
