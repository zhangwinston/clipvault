/// 全项目唯一用户可见文案源（DESIGN §7 UI 信息架构 / §8 权限与合规）。
///
/// 使用规则：
///  - 所有 UI 模块一律引用本文件常量，禁止在 Widget 中硬编码中文文案
///    （DESIGN §9-12：便于审核话术统一与后续多语言）；
///  - 全部成员均为 `static const String` 纯字面量，保证
///    `const Text(AppStrings.x)`、`const [...]` 等常量上下文合法；
///  - PRD 指定话术（免责声明、NSFW）逐字保留，不得改写；
///  - 技术性数值格式化（速率/体积/时长）由调用方完成，经单位常量拼接。
library;

abstract final class AppStrings {
  // ---------------- 通用（§8.4 / §4.2）----------------

  /// 上架名（§8.4，无 X/Twit 前缀；商店名、图标、相册名统一）。
  static const String appName = 'ClipVault';

  /// 数值前缀「约」：「约 24.5 MB」「约 12:05」。
  static const String about = '约';

  /// 变体行单位（§4.2 模板：`2.18 Mbps · 约 24.5 MB · MP4`）。
  static const String unitMbps = 'Mbps';
  static const String unitMB = 'MB';
  static const String tagMp4 = 'MP4';

  // ---------------- 底部导航（§7 IA：3 Tab）----------------

  static const String tabHome = '首页';
  static const String tabDownloads = '下载';

  /// 第三 Tab「我的」（§7：设置并入我的；亦用作我的页 AppBar 标题）。
  static const String tabSettings = '我的';

  // ---------------- 首页（§7.1）----------------

  /// 输入框 hint（含格式示例，对应 E01 提示）。
  static const String homeInputHint =
      '粘贴推文链接，如 https://x.com/用户名/status/…';
  static const String homePaste = '粘贴';
  static const String homeParse = '解析';
  static const String homeClear = '清空输入';

  /// 剪贴板 resume 识别横幅（§1.3-#4：PRD「浮窗」升级为内联横幅）。
  static const String clipboardBanner = '检测到推文视频链接，点击立即解析';

  /// 解析中骨架卡片主文案（§7.1，吸收 P2；耗时秒数由调用方拼接）。
  static const String parsingInProgress = '解析中…';

  /// 最近解析卡片区标题（内存态）。
  static const String recentParsed = '最近解析';

  // ---------------- 清晰度 Sheet（§4.2 / §7.2）----------------

  static const String qualitySheetTitle = '选择清晰度';

  /// 多视频 Chip 前缀，与序号拼接为「视频1」「视频2」。
  static const String qualityVideoChip = '视频';

  static const String qualityStartDownload = '开始下载';

  /// 加入下载队列 toast。
  static const String toastEnqueued = '已加入下载队列';

  // ---------------- 下载 Tab（§4.3 / §7.3）----------------

  static const String dlSectionActive = '进行中';
  static const String dlSectionQueued = '等待队列';
  static const String dlSectionFailed = '失败';
  static const String dlSectionHistory = '历史';
  static const String dlEmpty = '暂无下载记录';

  /// 429 全队列 30s 冷却提示（§4.3，吸收 P3）。
  static const String cooldownNotice = '触发限速，队列稍后自动继续';

  /// 已取消状态标签。
  static const String statusCanceled = '已取消';

  /// 无标题时的兜底标题，与推文 ID 拼接：「推文视频 123456」。
  static const String tweetFallbackTitle = '推文视频';

  /// 历史条目「未保存至相册」标记（权限被拒降级路径，§4.4）。
  static const String albumNotSaved = '未保存至相册';

  /// 下载失败兜底文案（errorCode 未识别时）。
  static const String errDownloadFailed = '下载失败';

  // ---------------- 任务/历史操作（§7.3）----------------

  static const String actionPause = '暂停';
  static const String actionResume = '继续';
  static const String actionCancel = '取消';
  static const String actionRetry = '重试';
  static const String actionDelete = '删除';
  static const String actionShare = '分享';
  static const String actionPlay = '播放';

  /// 权限被拒降级路径：历史条目重存入口（§4.4 / §8.1）。
  static const String actionResave = '重新保存至相册';
  static const String resaveSucceeded = '已保存至相册';
  static const String resaveFailed = '重新保存失败';
  static const String deleteConfirm = '确认删除该下载记录？';

  // ---------------- 我的 Tab（§4.6 / §7.4）----------------

  /// 法律区：免责声明重看入口（§8.3）。
  static const String settingsSectionLegal = '法律';
  static const String settingsDisclaimerRevisit = '重新查看《使用协议》';

  /// 已同意版本前缀，与版本号拼接：「已同意版本 1 → v1」。
  static const String settingsDisclaimerVersionPrefix = '已同意版本 ';

  /// 权限区：系统粘贴横幅/剪贴板 Toast 解释（§8.2）。
  static const String settingsSectionPermission = '权限';
  static const String settingsPermissionTitle = '权限说明';
  static const String settingsPermissionBody =
      '当您粘贴链接或回到前台时，系统可能显示粘贴提示横幅或 Toast，'
      '这是操作系统的行为。本应用仅在前台且您操作时读取剪贴板，'
      '用于识别推文链接，不会存储或上传剪贴板内容。';

  /// 缓存区（§4.4 缓存自动清理 + 手动清理）。
  static const String settingsSectionCache = '缓存';
  static const String settingsCacheUsage = '缓存占用';
  static const String settingsCacheClean = '清理缓存';
  static const String settingsCacheCleaned = '缓存已清理';

  /// 偏好区（P2）。
  static const String settingsSectionPrefs = '偏好设置';
  static const String settingsQualityMode = '首选清晰度';
  static const String settingsQualityHighest = '最高画质';
  static const String settingsQuality720p = '720P';
  static const String settingsConcurrency = '并发下载数';
  static const String settingsWifiOnly = '仅 Wi-Fi 下载';

  /// 诊断区（§7.4：配置版本，仅技术只读）。
  static const String settingsSectionDiag = '诊断';
  static const String settingsVersion = '版本信息';
  static const String settingsEndpointVersion = '端点配置版本';
  static const String settingsDiagHint = '以上为诊断信息，仅作技术只读展示。';

  // ---------------- 免责声明（§8.3，版本化）----------------

  /// 首启全屏《使用协议》标题。
  static const String disclaimerTitle = '使用协议';

  /// PRD §5 原文话术，逐字保留；版本化存储于 disclaimer.version。
  static const String disclaimerBody =
      '本工具仅供个人备份合法可公开访问的内容，禁止侵权与商业传播。';

  static const String disclaimerCheckbox = '我已阅读并同意《使用协议》';
  static const String disclaimerAgree = '同意并继续';
  static const String disclaimerDecline = '不同意';

  // ---------------- 七类错误一物一视图（§6.6；码值同 contracts/error_codes.md）----------------

  /// E01 UrlInvalid：提示格式示例，零网络请求。
  static const String errUrlInvalid = '链接无效';
  static const String errUrlInvalidHint =
      '链接格式不正确，请粘贴形如 https://x.com/用户名/status/推文ID 的完整链接。';

  /// E02 NetworkTimeout：退避 3 次自动重试后透出 + 一键重试按钮。
  static const String errNetworkTimeout = '网络连接失败或超时，请检查网络后重试。';

  /// E03 RateLimited：触发备源切换（403 不归「锁推」）。
  static const String errRateLimited = '触发限频';
  static const String errRateLimitedHint = '解析请求被限流，已尝试备用解析源，请稍后重试。';

  /// E04 TweetNotFound：锁推通常表现为 404/空{}，合并提示 + 补充文案。
  static const String errTweetNotFound = '推文不存在';
  static const String errTweetNotFoundHint =
      '推文不存在或已删除；非公开（受保护）推文无法解析。';

  /// E05 NotVideoTweet。
  static const String errNotVideoTweet = '该推文不是视频推文。';

  /// E06 RestrictedContent：PRD 指定话术逐字保留；不加载缩略图由行为层保证（§8.5）。
  static const String errRestrictedContent = '该视频受内容限制，无法匿名解析。';

  /// E07 EndpointDrift：驱动端点配置刷新检查（§6.7）。
  static const String errEndpointDrift = '解析服务暂不可用，请升级 App 版本。';

  /// 重复入队提示（引擎按 (tweetId, bitrate) 业务键去重时 UI 展示）。
  static const String taskAlreadyQueued = '该视频已在下载队列中';

  /// 下载失败细分（errorCode 存 DownloadFailureKind.name，UI 按名映射）。
  static const String errDownloadUrlExpired = '下载链接已过期，请重试';
  static const String errDownloadPermanent = '下载失败，文件可能已不可用';

  /// 已用时间标签（PRD 3.3 实时状态「已用时间与剩余预估时间」）。
  static const String labelElapsed = '已用';

  /// 「仅 Wi-Fi 下载」开启时非 Wi-Fi 入队提示（任务挂起待连 Wi-Fi 自动开始）。
  static const String taskWaitingWifi = '当前非 Wi-Fi，任务已挂起，连接 Wi-Fi 后自动开始';

  /// 设置/应用加载失败等非网络类兜底文案（不渲染原始异常）。
  static const String errGeneric = '出错了，请稍后重试';
}
