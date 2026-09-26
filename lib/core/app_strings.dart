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

  /// 双色字标两段（BrandTitle：Clip=onSurface / Vault=primary）。
  static const String appNameA = 'Clip';
  static const String appNameB = 'Vault';

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

  /// 合并主 CTA（视觉评审主题 G：双按钮动线冗余 → 单一「粘贴并解析」）。
  static const String homePasteAndParse = '粘贴并解析';

  /// 输入为空且剪贴板无链接时的反馈（此前静默无反应）。
  static const String homeEmptyInput = '先复制一条视频链接，或直接粘贴到输入框';

  static const String homeClear = '清空输入';

  /// 剪贴板 resume 识别横幅（§1.3-#4：PRD「浮窗」升级为内联横幅）。
  static const String clipboardBanner = '检测到推文视频链接，点击立即解析';

  /// 横幅副文案前缀（与推文 ID 尾号拼接：「推文 …43991」）。
  static const String clipboardBannerTweetPrefix = '推文';

  /// 首次出现剪贴板横幅时的一次性内联说明（§8.2 前置解释）。
  static const String clipboardBannerExplain =
      '说明：回到前台时读取剪贴板以识别推文链接，不会存储或上传内容，'
      '详见「我的 · 权限说明」。';

  /// 解析中骨架卡片主文案（§7.1，吸收 P2；耗时秒数由调用方拼接）。
  static const String parsingInProgress = '解析中…';

  /// 退避重试轮次前缀（与「（2/3）」拼接：「正在重试（2/3）…」）。
  static const String parseRetrying = '正在重试';

  /// 解析取消按钮（骨架卡上，弱网长等待时可中止）。
  static const String actionCancelParse = '取消解析';

  /// 首页使用引导卡（空态三步示意）标题。
  static const String homeGuideTitle = '三步保存推文视频';

  static const String homeGuideStep1 = '① 在 X 打开视频推文，复制链接';
  static const String homeGuideStep2 = '② 回到这里粘贴并点「解析」';
  static const String homeGuideStep3 = '③ 选择清晰度，完成后自动存入相册';
  static const String homeGuideShareHint = '也可以在 X 里直接「分享」链接给 ClipVault';

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

  /// 下载 Tab 空态行动按钮（点击切回首页）。
  static const String dlEmptyAction = '去解析第一个视频';

  /// 429 全队列 30s 冷却提示（§4.3，吸收 P3）；带倒计时形态由前后缀拼接。
  static const String cooldownNotice = '触发限速，队列稍后自动继续';
  static const String cooldownNoticePrefix = '触发限速，约 ';
  static const String cooldownNoticeSuffix = ' 秒后自动继续';

  /// 仅 Wi-Fi 偏好挂起任务的状态标签（区别于普通排队）。
  static const String waitingWifiLabel = '等待 Wi-Fi 连接';

  /// 429 冷却期间被系统暂停的任务标签（区别于用户手动暂停）。
  static const String cooldownPausedLabel = '限速等待中';

  /// 冷却中点「继续」的即时反馈。
  static const String resumeInCooldown = '冷却中，稍后自动继续';

  /// 已取消状态标签。
  static const String statusCanceled = '已取消';

  /// 取消成功 + 撤销动作（Snackbar）。
  static const String taskCanceled = '已取消下载';
  static const String actionUndo = '撤销';

  /// 下载完成通知（前台 Snackbar）。
  static const String toastDownloadDone = '已下载完成并保存至相册';
  static const String toastDownloadDoneNoAlbum = '已下载完成（未保存至相册，可在历史中重新保存）';
  static const String actionView = '查看';

  /// 无标题时的兜底标题，与推文 ID 拼接：「推文视频 123456」。
  static const String tweetFallbackTitle = '推文视频';

  /// 历史条目「未保存至相册」标记（权限被拒降级路径，§4.4）。
  static const String albumNotSaved = '未保存至相册';

  /// 清理缓存后本地文件已删除的标记（行保留、文件不在）。
  static const String fileCleaned = '本地文件已清理';

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
  /// 常驻入口的两个标签：未保存过用「保存至相册」，保存过用「重新保存至相册」。
  static const String actionResave = '重新保存至相册';
  static const String actionSaveToAlbum = '保存至相册';
  static const String resaveSucceeded = '已保存至相册';
  static const String resaveFailed = '重新保存失败';

  /// 删除确认文案（明示会一并删除本地文件；相册副本不受影响）。
  static const String deleteConfirm =
      '将删除该记录及本地视频文件；已保存至系统相册的副本不受影响。';

  /// 分享不可用反馈（文件异常等场景）。
  static const String shareUnavailable = '分享功能暂不可用';

  // ---------------- 我的 Tab（§4.6 / §7.4）----------------

  /// 法律区：免责声明重看入口（§8.3）。
  static const String settingsSectionLegal = '法律';
  static const String settingsDisclaimerRevisit = '重新查看《使用协议》';

  /// 已同意版本前缀，与版本号拼接：「已同意版本 v1」/「已同意版本 v1 → v2」。
  static const String settingsDisclaimerVersionPrefix = '已同意版本 ';

  /// 从未同意过条款时的副标题。
  static const String settingsDisclaimerNone = '尚未同意《使用协议》';

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
  static const String settingsCacheEmpty = '没有可清理的缓存';

  /// 清理确认弹窗（列明实际影响；N/X 由调用方拼接）。
  static const String settingsCacheCleanConfirmTitle = '清理缓存';
  static const String settingsCacheCleanConfirmPrefix = '将删除 ';
  static const String settingsCacheCleanConfirmMiddle = ' 个视频的本地副本（共 ';
  static const String settingsCacheCleanConfirmSuffix =
      '）；已保存至系统相册的不受影响。';

  /// 相册权限预解释（首次保存前）。
  static const String albumExplainTitle = '保存到系统相册';
  static const String albumExplainBody =
      '下载完成后会请求相册权限以保存视频。拒绝后视频仍会保留在应用内，'
      '可随时在历史中重新保存。';
  static const String albumExplainConfirm = '知道了';

  /// 偏好区（P2）。
  static const String settingsSectionPrefs = '偏好设置';
  static const String settingsQualityMode = '首选清晰度';
  static const String settingsQualityHighest = '最高画质';
  static const String settingsQuality720p = '720P';
  static const String settingsConcurrency = '并发下载数';
  static const String settingsWifiOnly = '仅 Wi-Fi 下载';

  /// 关于区（§7.4；视觉评审主题 H：原「诊断」术语对普通用户是天书）。
  static const String settingsSectionDiag = '关于';
  static const String settingsVersion = '版本信息';
  static const String settingsEndpointVersion = '解析服务配置';
  static const String settingsDiagHint = '以上信息仅作技术只读展示。';

  /// 版本信息点击弹窗：仓库链接展示与复制。
  static const String settingsRepoLink = '仓库地址（GitHub）';
  static const String settingsCopyLink = '复制链接';
  static const String settingsLinkCopied = '链接已复制';
  static const String settingsClose = '关闭';

  // ---------------- 免责声明（§8.3，版本化）----------------

  /// 首启全屏《使用协议》标题。
  static const String disclaimerTitle = '使用协议';

  /// PRD §5 原文话术，逐字保留；版本化存储于 disclaimer.version。
  static const String disclaimerBody =
      '本工具仅供个人备份合法可公开访问的内容，禁止侵权与商业传播。';

  static const String disclaimerCheckbox = '我已阅读并同意《使用协议》';
  static const String disclaimerAgree = '同意并继续';
  static const String disclaimerDecline = '不同意';

  /// 条款版本升级重弹场景的前缀说明（正文保持 PRD 逐字话术）。
  static const String disclaimerUpdatedPrefix = '条款已更新，请重新阅读：';

  /// 拒绝后的静态闸门页文案（iOS 无可靠退出 API，改为引导用户自行离开）。
  static const String disclaimerDeclinedTitle = '需同意《使用协议》后才能使用';
  static const String disclaimerDeclinedBody =
      '您尚未同意《使用协议》。可以上滑回到桌面稍后再来，'
      '或点击下方按钮重新查看协议。';
  static const String disclaimerReviewAgain = '重新查看协议';

  /// 闸门品牌页三步示意（兼作首屏自我解释）。
  static const String gateAppNameSubtitle = '推文视频保存工具';
  static const String gateStep1 = '复制推文链接';
  static const String gateStep2 = '解析并选择清晰度';
  static const String gateStep3 = '自动保存至相册';

  // ---------------- 七类错误一物一视图（§6.6；码值同 contracts/error_codes.md）----------------

  /// E01 UrlInvalid：提示格式示例，零网络请求。
  static const String errUrlInvalid = '链接无效';
  static const String errUrlInvalidHint =
      '链接格式不正确，请粘贴形如 https://x.com/用户名/status/推文ID 的完整链接。';

  /// E02 NetworkTimeout：退避 3 次自动重试后透出 + 一键重试按钮。
  static const String errNetworkTimeout = '网络连接失败或超时，请检查网络后重试。';

  /// E03 RateLimited（403 不归「锁推」）。
  /// 话术诚实性约束：备源真正接入编排（fallback.enabled）之前，
  /// 不得声称「已尝试备用解析源」。
  static const String errRateLimited = '触发限频';
  static const String errRateLimitedHint = '解析请求被限流，请稍后 1-2 分钟后重试。';

  /// E04 TweetNotFound：锁推通常表现为 404/空{}，合并提示 + 补充文案。
  static const String errTweetNotFound = '推文不存在';
  static const String errTweetNotFoundHint =
      '推文不存在或已删除；非公开（受保护）推文无法解析。';

  /// E05 NotVideoTweet。
  static const String errNotVideoTweet = '该推文不是视频推文。';

  /// E06 RestrictedContent：PRD 指定话术逐字保留；不加载缩略图由行为层保证（§8.5）。
  static const String errRestrictedContent = '该视频受内容限制，无法匿名解析。';

  /// E07 EndpointDrift：驱动端点配置刷新检查（§6.7）。
  /// 可重试（配置刷新可能成功/瞬时结构异常），避免最新版用户走进死胡同。
  static const String errEndpointDrift = '解析服务暂不可用，请稍后重试或升级 App 版本。';
  static const String errEndpointDriftHint = '若已是最新版本，问题将随后续更新修复。';

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

  // ---------------- 内置播放器（§4.5 / P1-9）----------------

  /// 播放失败兜底（不向用户渲染含沙盒路径的原始异常串）。
  static const String errPlayerLoad = '视频无法播放，文件可能已删除或格式不受支持。';

  static const String actionPlayPause = '播放/暂停';
  static const String actionFullscreen = '全屏';
  static const String actionExitFullscreen = '退出全屏';
  static const String actionBack = '返回';

  /// 手势进度调节的无障碍标签。
  static const String playerSeekLabel = '横向拖动调节进度';
  static const String playerVolumeLabel = '左侧上下拖动调节音量';
}
