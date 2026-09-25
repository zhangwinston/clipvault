// downloadErrorMessage 契约测试（review C3）：
// 引擎侧 DownloadFailureKind.name（'retryable'/'urlExpired'/'permanent'）
// 与解析域 'E01'~'E07' 两个取值域都按各自文案映射，未知值回落通用语；
// 此前 failureKind.name 全部落入 default 展示无差别「下载失败」。

import 'package:flutter_test/flutter_test.dart';
import 'package:clipvault/core/app_strings.dart';
import 'package:clipvault/ui/common/error_views.dart';

void main() {
  group('downloadErrorMessage：DownloadFailureKind.name 域（引擎落库值）', () {
    test('retryable → 网络超时话术（重试有意义）', () {
      expect(
        downloadErrorMessage('retryable'),
        AppStrings.errNetworkTimeout,
      );
    });

    test('urlExpired → 直链过期专属话术', () {
      expect(
        downloadErrorMessage('urlExpired'),
        AppStrings.errDownloadUrlExpired,
      );
    });

    test('permanent → 不可用专属话术（区别于通用失败）', () {
      expect(
        downloadErrorMessage('permanent'),
        AppStrings.errDownloadPermanent,
      );
    });
  });

  group('downloadErrorMessage：解析域 E01~E07（启动恢复/历史行）', () {
    test('E02 → 网络超时话术', () {
      expect(downloadErrorMessage('E02'), AppStrings.errNetworkTimeout);
    });

    test('E04 → 推文不存在话术', () {
      expect(downloadErrorMessage('E04'), AppStrings.errTweetNotFound);
    });
  });

  test('未知/空 errorCode 回落通用「下载失败」', () {
    expect(downloadErrorMessage('E99'), AppStrings.errDownloadFailed);
    expect(downloadErrorMessage(null), AppStrings.errDownloadFailed);
  });
}
