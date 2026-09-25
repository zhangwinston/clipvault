# ClipVault 错误码契约（E01~E07 + DownloadError）

> 单一事实源：DESIGN §6.6。本文件是 `lib/core/error.dart`（sealed ParseError 七类 + DownloadError）与
> `lib/core/app_strings.dart`（UI 话术收口）、`lib/ui/common/error_views.dart`（一物一视图）的契约基准。
> Dart 侧枚举名、码值、触发条件、UI 动作不得偏离本表；若确需变更，必须同步修改本文件并在
> contractDeviations 中申报。

## ParseError（解析域，sealed，七类）

| 码 | 枚举名 | 触发条件（实测依据） | UI 动作（文案常量收口于 app_strings.dart） |
|---|---|---|---|
| E01 | `UrlInvalid` | 正则/位数/int64 校验不过（§4.1：15~20 位数字 + int64 范围双重校验） | 提示格式示例；**零网络请求** |
| E02 | `NetworkTimeout` | 网络层异常 / DNS / 6s 接收超时 | 退避 3 次自动重试后透出 + 一键重试按钮 |
| E03 | `RateLimited` | 上游 429 / 403 风控（**独立分类**；403 不归"锁推"） | 触发备源切换；下载语境另触发全队列 30s 冷却（§4.3） |
| E04 | `TweetNotFound` | HTTP 404 / dogpage HTML（content-type text/html）/ 200 + 空 `{}` | "推文不存在或已删除"；附"非公开推文无法解析"补充文案（锁推通常表现为 404/空{}） |
| E05 | `NotVideoTweet` | 200 合法 JSON 但 mediaDetails 无 type ∈ {video, animated_gif} 条目 | "该推文不是视频推文" |
| E06 | `RestrictedContent` | possibly_sensitive == true 或媒体字段缺失受限启发式 | "该视频受内容限制，无法匿名解析"（PRD 指定话术）；**不加载缩略图**（NSFW 双保险） |
| E07 | `EndpointDrift` | `__typename != 'Tweet'` 或关键字段结构性缺失（守卫配置见 endpoints.json 的 driftGuard） | "解析服务暂不可用，请升级 App 版本"；同时驱动端点配置刷新检查（§6.7）+ 本地哨兵日志 |

### 约束

- sealed 类 + 穷举 switch：编译期强制七类全覆盖；一物一视图（`error_views.dart`）。
- E03 与 E04 的区分红线：403 在**解析语境**归 `RateLimited`（风控/限频），在**下载语境**为直链签名过期
  （`DownloadError.urlExpired`，自动重解析刷新，§4.3）；任何实现不得把 403 归入"锁推"提示。
- E06 不加载缩略图是硬性约束（NSFW 双保险之一）。

### 实现注记（2026-09-25 真实端点录制发现）

- **mediaDetails 可整体缺失**：纯文本推文（实测 id=20，`__typename=="Tweet"`、HTTP 200）响应中
  没有 `mediaDetails` 字段。解析器必须把"`mediaDetails` 缺失 / 空数组 / 无 type ∈ {video,
  animated_gif} 条目"三者统一归 **E05 NotVideoTweet**；`__typename` 与 `user.screen_name` 正常时
  不得因 mediaDetails 缺失而误报 E07（EndpointDrift 守卫针对响应整体形状，见
  `assets/config/endpoints.json` 的 driftGuard）。
- **空 body `{}` 判定**：无 token 请求返回 HTTP 200 + body 逐字为 `{}`（见
  `syndication_empty.json`），按 E04 TweetNotFound 特判。
- **404 dogpage**：HTTP 404 + content-type `text/html`，body 为 `class="dog"` 的错误页（见
  `syndication_404_dogpage.html`），按 E04。

## DownloadError（下载域，引擎内部区分）

| 枚举值 | 语义 | 引擎行为 |
|---|---|---|
| `retryable` | 网络类错误 | 指数退避 800ms×2^n + 抖动，3 次后 `failed(retryable=true)` 供一键重试 |
| `permanent(reason)` | 404 等不可恢复 | 直接 `failed(permanent)`，不重试 |
| `urlExpired` | 403/410 直链签名过期 | **自动回炉重解析刷新直链一次**（复用 tweetId，仅刷新 URL 不丢进度）再重试 |

另：HTTP 429 → 不属于单任务 DownloadError，而是触发**全队列 30s 冷却**（暂停所有 running/queued，
30s 后自动恢复，UI 提示"触发限速，队列稍后自动继续"）。

## 夹具 ↔ 错误分类对照（测试断言基准）

| 夹具文件 | 期望分类 |
|---|---|
| `syndication_video_ok.json` | 成功（ResolveResult, parserVersion=syndication-v1） |
| `syndication_multi_video.json` | 成功（videoCount=2，variants 为当前选中视频的档位） |
| `syndication_photo_only.json` | E05 NotVideoTweet |
| `syndication_404_dogpage.html` | E04 TweetNotFound |
| `syndication_empty.json` | E04 TweetNotFound（200 + 空 `{}` 特判） |
| `syndication_sensitive.json` | E06 RestrictedContent |
| `fxtwitter_status_ok.json` | 成功（ResolveResult, parserVersion=fxtwitter-v1） |
