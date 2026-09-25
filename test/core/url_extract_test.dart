import 'package:flutter_test/flutter_test.dart';

import 'package:clipvault/core/url_extract.dart';

/// url_extract 全形态测试（DESIGN §11.1）。
void main() {
  group('标准形态', () {
    test('x.com / twitter.com，http/https', () {
      expect(
          extractTweetId('https://x.com/elonmusk/status/1790637656616943991'),
          '1790637656616943991');
      expect(
          extractTweetId('https://twitter.com/elonmusk/status/1790637656616943991'),
          '1790637656616943991');
      expect(
          extractTweetId('http://x.com/a/status/1790637656616943991'),
          '1790637656616943991');
    });

    test('子域：www / m / mobile / web', () {
      expect(
          extractTweetId('https://www.twitter.com/u/status/1790637656616943991'),
          '1790637656616943991');
      expect(
          extractTweetId('https://m.twitter.com/u/status/1790637656616943991'),
          '1790637656616943991');
      expect(
          extractTweetId('https://mobile.x.com/u/status/1790637656616943991'),
          '1790637656616943991');
      // DESIGN §4.1 明确要求容忍的 web 子域 + 无用户名 i/web 形态
      expect(
          extractTweetId('https://web.twitter.com/i/web/status/1790637656616943991'),
          '1790637656616943991');
      expect(
          extractTweetId('https://twitter.com/i/web/status/1790637656616943991'),
          '1790637656616943991');
    });

    test('statuses 拼写变体', () {
      expect(
          extractTweetId('https://x.com/u/statuses/1790637656616943991'),
          '1790637656616943991');
    });

    test('/video/N 后缀与 ?s=20&t= 查询串', () {
      expect(
          extractTweetId('https://x.com/u/status/1790637656616943991/video/1'),
          '1790637656616943991');
      expect(
          extractTweetId('https://x.com/u/status/1790637656616943991/video/2?s=20'),
          '1790637656616943991');
      expect(
          extractTweetId('https://twitter.com/u/status/1790637656616943991?s=20&t=abc'),
          '1790637656616943991');
      expect(
          extractTweetId('https://x.com/i/web/status/1790637656616943991/video/1?s=20'),
          '1790637656616943991');
    });

    test('大小写不敏感（分享文本中大写域名）', () {
      expect(
          extractTweetId('HTTPS://X.COM/u/status/1790637656616943991'),
          '1790637656616943991');
    });
  });

  group('分享文案混排（§4.1 输入通道 2/3）', () {
    test('中英文空格混排', () {
      expect(
          extractTweetId(
              '看看这个 video https://x.com/u/status/1790637656616943991?s=20 超好看'),
          '1790637656616943991');
    });

    test('中文紧贴链接两侧（无空格）', () {
      expect(extractTweetId('链接https://x.com/u/status/1790637656616943991在此'),
          '1790637656616943991');
    });

    test('多个链接取首个命中', () {
      expect(
          extractTweetId(
              'https://twitter.com/a/status/1790637656616943991 以及 https://x.com/b/status/1234567890123456789'),
          '1790637656616943991');
    });

    test('前后换行与空白', () {
      expect(
          extractTweetId('  \nhttps://x.com/u/status/1790637656616943991\n  '),
          '1790637656616943991');
    });
  });

  group('Tweet ID 双重校验（15~20 位 + int64）', () {
    test('14 位不过 → null', () {
      expect(extractTweetId('https://x.com/u/status/12345678901234'), isNull);
    });
    test('21 位不过 → null', () {
      expect(extractTweetId('https://x.com/u/status/123456789012345678901'), isNull);
    });
    test('19 位但超 int64 上限 → null', () {
      expect(
          extractTweetId('https://x.com/u/status/9223372036854775808'), isNull);
    });
    test('int64 上限边界值通过', () {
      expect(
          extractTweetId('https://x.com/u/status/9223372036854775807'),
          '9223372036854775807');
    });
    test('15 位下界通过（2010 早期雪花 ID）', () {
      expect(extractTweetId('https://x.com/u/status/100000000000000'),
          '100000000000000');
    });
    test('20 位因超 int64 上限被拒（int64 最大为 19 位）', () {
      expect(extractTweetId('https://x.com/u/status/12345678901234567890'),
          isNull);
    });
  });

  group('非法输入 → null（E01 UrlInvalid，零网络请求）', () {
    test('非 x/twitter 域', () {
      expect(extractTweetId('https://youtube.com/watch?v=abc'), isNull);
      expect(extractTweetId('https://fakex.com/u/status/1790637656616943991'), isNull);
      expect(extractTweetId('https://x.com.evil.com/u/status/1790637656616943991'),
          isNull);
    });
    test('缺 scheme', () {
      expect(extractTweetId('x.com/u/status/1790637656616943991'), isNull);
    });
    test('t.co 短链（P1 项，P0 不解析）', () {
      expect(extractTweetId('https://t.co/AbCdEf1234'), isNull);
    });
    test('空输入与纯空白', () {
      expect(extractTweetId(''), isNull);
      expect(extractTweetId('   \n '), isNull);
    });
  });

  group('extractTweetUrl 详细产出', () {
    test('归一化 URL 去子域/查询/视频后缀', () {
      final ExtractedTweetUrl? result = extractTweetUrl(
          'https://mobile.twitter.com/u/status/1790637656616943991/video/1?s=20');
      expect(result, isNotNull);
      expect(result!.tweetId, '1790637656616943991');
      expect(result.normalizedUrl,
          'https://x.com/i/web/status/1790637656616943991');
    });

    test('值相等语义（横幅去重键）', () {
      expect(extractTweetUrl('https://x.com/a/status/1790637656616943991'),
          extractTweetUrl('https://twitter.com/b/status/1790637656616943991?s=20'));
    });
  });

  group('isValidTweetId 单元', () {
    test('位数边界', () {
      expect(isValidTweetId('12345678901234'), isFalse); // 14
      expect(isValidTweetId('123456789012345'), isTrue); // 15
      expect(isValidTweetId('9223372036854775807'), isTrue); // 19 位 int64 上限
      expect(isValidTweetId('12345678901234567890'), isFalse); // 20 位但超 int64
      expect(isValidTweetId('123456789012345678901'), isFalse); // 21
    });
    test('非数字拒绝', () {
      expect(isValidTweetId('17906376566169439ab'), isFalse);
      expect(isValidTweetId('1790637656616943991 '), isFalse);
    });
    test('int64 范围', () {
      expect(isValidTweetId('9223372036854775807'), isTrue);
      expect(isValidTweetId('9223372036854775808'), isFalse);
    });
  });
}
